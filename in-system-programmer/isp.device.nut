/**
 * Copyright 2014 George C. Hawkins
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */
 
// Tables don't support plus or append(...).
function merge(src, dest) {
    foreach (slot, value in src) {
        dest[slot] <- value;
    }
}

function setFuses(data) {
    local lfuse = data.lfuse;
    local hfuse = data.hfuse;
    local efuse = data.efuse;
    
    programmer.setFuses(lfuse, hfuse, efuse);
}

function setLockBits(data) {
    local lockBits = data.lockBits;
    
    programmer.setLock(lockBits);
}

function uploadHex(data) {
    showMemory(); // Log how the HEX blob impacted memory.
    
    // Unlike elsewhere the items, due to their size, are deleted in order
    // to avoid sending them back in the response.
    local hexData = delete data.hexData;
    local part = delete data.part;

    programmer.uploadHex(part, hexData);
}

function handleActionSendImpl(data) {
    try {
        switch (data.action) {
        case "getSignature":
            data.signature <- programmer.getSignature();
            break;
        case "getFuses":
            merge(programmer.getFuses(), data);
            break;
        case "setFuses":
            setFuses(data);
            break;
        case "getLockBits":
            data.lockBits <- programmer.getLockBits();
            break;
        case "setLockBits":
            setLockBits(data);
            break;
        case "uploadHex":
            uploadHex(data);
            break;
        case "test":
            handleActionSend = testHandleActionSendImpl;
            data.test <- true;
            break;
        default:
            throw "unknow action" + data.action;
        }
        agent.send("actionSuccessReply", data);
    } catch (ex) {
        data.message <- ex.tostring();
        agent.send("actionFailureReply", data);
    }
}

handleActionSend <- handleActionSendImpl;

function testHandleActionSendImpl(data) {
    if (data.action == "test") {
        handleActionSend = handleActionSendImpl;
        data.test <- false;
        agent.send("actionSuccessReply", data);
    } else {
        data.message <- "testing response to " + data.action + " failure";
        agent.send("actionFailureReply", data);
    }
}

// A HEX blob can eat up the Imp's memory - log free memory every so often to spot issues.
function showMemory() {
    server.log("Info: free memory=" + imp.getmemoryfree() + "B");
}

function dispatchActionSend(data) {
    handleActionSend(data);
}

agent.on("actionSend", dispatchActionSend);

// -----------------------------------------------------------------------------
// Start - In-System Programmer library
// -----------------------------------------------------------------------------
class Fuses {
    WRITE_LOCK  = 0xACE00000;
    WRITE_LFUSE = 0xACA00000;
    WRITE_HFUSE = 0xACA80000;
    WRITE_EFUSE = 0xACA40000;
    READ_LOCK   = 0x58000000;
    READ_LFUSE  = 0x50000000;
    READ_HFUSE  = 0x58080000;
    READ_EFUSE  = 0x50080000;
    
    // http://sourceforge.net/p/ethernut/code/5726/tree/trunk/nut/dev/avrtarget.c
    // Oddly Nut don't consider DWEN dangerous. It's added here as it disables ISP.
    // These values are appropriates for many AVR MCUs but aren't universal.
    NEVER_PROG = {
        lfuse = 0x62 // 0110 0010 CKOUT, SUT1 / CKSEL1
        hfuse = 0xC0 // 1100 0000 RSTDISBL, DWEN
        efuse = 0xF8 // 1111 1000 unused bits
    };
    ALWAYS_PROG = {
        lfuse = 0x1D // 0001 1101 SUT0 / CKSEL3, CKSEL2, CKSEL0
        hfuse = 0x20 // 0010 0000 SPIEN
        efuse = 0x00 // 0000 0000
    }
    // SAFE = {
    //   1000 0000 CKDIV8
    //   0101 1111 WDTON / EESAVE, varies
    //   0000 0111 varies
    // }
    spi = null;

    constructor(_spi) {
        spi = _spi;
    }
    
    function spiTransaction(i, offset = 3) {
        local out = blob(4);
        
        out.writen(i, 'i');
        out.swap4();
        
        server.log(format("0x%02x%02x%02x%02x", out[3], out[2], out[1], out[0]));
        
        return spi.writeread(out)[offset];
    }

    function readLfuse() {
        return spiTransaction(READ_LFUSE);
    }
    
    function readHfuse() {
        return spiTransaction(READ_HFUSE);
    }
    
    function readEfuse() {
        return spiTransaction(READ_EFUSE);
    }
    
    function readLock() {
        return spiTransaction(READ_LOCK);
    }
    
    // TODO: remove/merge with other one.
    function pollUntilReady() {
        local POLL_READY = 0xF0000000;
        local count = 1;
        local start = hardware.micros();
        
        // TODO: some MCUs apparently don't support POLL_READY. The families containing
        // the 328 and the ATtinyX5s both support POLL_READY. To check for a different
        // family look for the "Serial Programming Instruction Set" table in the MCUs
        // datasheet - one should find Poll RDY. If not one should simply wait here for
        // the time given for WD_FLASH in the datasheet. Nick Gammon waits 10ms in
        // https://github.com/nickgammon/arduino_sketches/blob/master/Atmega_Board_Programmer/Atmega_Board_Programmer.ino
        while ((spiTransaction(POLL_READY) & 0x01) != 0x00) {
            count++;
        }
        
        local diff = hardware.micros() - start;
        server.log("Info: polled " + count + " times over " + diff + "us");
    }

    function writeFuse(instruction, value) {
        spiTransaction(instruction | value);
        pollUntilReady();
    }
    
    function writeSafeFuse(name, instruction, value) {
        local check = (value | NEVER_PROG[name]) & ~ALWAYS_PROG[name];
        
        // If you know better then override this check.
        if (value != check)
            throw value + " is not safe for " + name;

        writeFuse(instruction, value);
    }
    
    function writeLfuse(value) {
        writeSafeFuse("lfuse", WRITE_LFUSE, value);
    }
    
    function writeHfuse(value) {
        writeSafeFuse("hfuse", WRITE_HFUSE, value);
    }
    
    function writeEfuse(value) {
        writeSafeFuse("efuse", WRITE_EFUSE, value);
    }
    
    function writeLock(value) {
        if ((value & ~readLock()) != 0) {
            throw "programmed lock bits can only be reset with chip erase";
            // The simplest way to erase the chip is to upload an image.
        }
        writeFuse(WRITE_LOCK, value);
    }
}

class InSystemProgrammer {
    SPICLK = 250; // 250KHz - slow enough for processors like the ATtiny.
    PROGRAM_ENABLE = 0xAC;
    PROGRAM_ACK = 0x53;
    READ_SIGNATURE = 0x30;
    READ_LFUSE = 0x50;
    READ_EFUSE = "\x50\x08";
    READ_HFUSE = "\x58\x08";
    READ_LOCK = 0x58;
    CHIP_ERASE = 0x80;
    
    HEX_TYPE_END = 0x01;

    spi = null;
    reset = null;
    fuses = null;

    constructor() {
        fuses = Fuses(spi);
        
        reset.configure(DIGITAL_OUT);
        
        // Reset is held low during programming - so set it high initially to
        // leave chip to run as normal.
        reset.write(1);
            
        // I've confirmed MSB_FIRST and CLOCK_IDLE_LOW are the values used by the Arduino programmer by
        // printing out SPCR and decoding it using http://avrbeginners.net/architecture/spi/spi.html
        local speed = spi.configure((MSB_FIRST | CLOCK_IDLE_LOW), SPICLK);
        
        server.log("speed: " + speed + "KHz");
    }
    
    function run(action) {
        startProgramming();
        
        try {
            local result = action();
    
            endProgramming();
            
            return result;
        } catch (ex) {
            endProgramming();
            
            throw ex;
        }
    }
    
    function getSignature() {
        return run(function() {
            local sig = [];
            
            for (local i = 0; i < 3; i++) {
                sig.append(program(READ_SIGNATURE, 0, i));
            }
            
            return sig;
        });
    }
    
    function getFuses() {
        return run(function() {
            return {
                lfuse = fuses.readLfuse()
                hfuse = fuses.readHfuse()
                efuse = fuses.readEfuse()
            };
        });
    }
    
    function getLockBits() {
        return run(function() {
            return fuses.readLock();
        });
    }
    
    function setFuses(lfuse, hfuse, efuse) {
        run(function() {
            fuses.writeLfuse(lfuse)
            fuses.writeHfuse(hfuse)
            fuses.writeEfuse(efuse)
        });
    }

    // TODO: standardize on one of set/write, get/read, lock/lockBits, sketch/image/HexData   
    function setLock(lock) {
        run(function() {
           fuses.writeLock(lock);
        });
    }

    function uploadHex(part, hexData) {
        return run(function() {
            local chipSize = part.memories.flash.size;
            local page = blob(part.memories.flash.page_size);
            local pageAddr = 0;
            
            chipErase();

            while (pageAddr < chipSize) {
                if (readPage(hexData, pageAddr, page)) {
                    flashPage(pageAddr, page);
                }

                pageAddr += page.len();
            }
            
            verifyImage(hexData);
        });
    }
    
    function verifyImage(hexData) {
        hexData.seek(0);
        
        while (!hexData.eos()) {
            local line = readLine(hexData);

            if (line.type == HEX_TYPE_END) {
                break;
            }
            
            if (line.len == 0) {
                continue;
            }
            
            local addr = line.addr;
            local data = line.data;

            while (!data.eos()) {
                local t1 = addr % 2 == 0 ? 0x20 : 0x28; // High or low byte of word.
                local t3 = addr >> 1;
                local t2 = t3 >> 8;
                local actual = spiTransaction(t1, t2, t3) & 0xff;
                local expected = data.readn('b');
                
                if (actual != expected) {
                    throw format("expected 0x%02x but found 0x%02x at 0x%04x", expected, actual, addr)
                }
                
                addr++;
            }
        }
    }

    // TODO: remove
    i = 0
    function dumpPage(pageAddr, page) {
        server.log(format("XXX%d pageAddr=0x%04x", i++, pageAddr));
        local out = "";
        local count = 0;
        
        while (!page.eos()) {
            out += format("%02X", page.readn('b'));
            if (++count == 16) {
                server.log(format("XXX%d %s", i++, out));
                out = "";
                count = 0;
            }
        }
        
        if (count != 0) {
            server.log(format("XXX%d %s", i++, out));
        }
        
        page.seek(0);
    }

    function flashPage(pageAddr, page) {
//        dumpPage(pageAddr, page);
        
        local offset = 0;
        
        while (!page.eos()) {
            flashWord(offset++, page.readn('b'), page.readn('b'));
        }
        
        commitPage(pageAddr);
    }
    
    function flashWord(offset, wordLow, wordHigh) {
        local addrHigh = offset >> 8 & 0xFF;
        local addrLow = offset & 0xFF;
        
        //server.log(format("XXX%d 0x%04x 0x%02x 0x%02x - 0x%02x 0x%02x", i++, offset, addrHigh, addrLow, wordLow, wordHigh));
        
        program(0x40, addrHigh, addrLow, wordLow);
        program(0x48, addrHigh, addrLow, wordHigh);
    }
    
    function commitPage(pageAddr) {
        // IMPORTANT: both Adafruit and Nick Gammon AND the address with a mask.
        // This is only necessary to get the start of page address for an arbitrary address.
        // So this isn't required here as the passed in address is always the start of a page.
        // If you do need a mask then it needs to be calculated according to the page size:
        //   local mask = ~(page.len() - 1)
        // Nick Gammon handles this correctly - Adafruit hardcode for the 128B page size of the ATMega16 and ATMega32 famalies.
        local wordAddr = pageAddr >> 1;
        local addrHigh = wordAddr >> 8 & 0xFF;
        local addrLow = wordAddr & 0xFF;
        
        local result = spiTransaction(0x4C, addrHigh, addrLow);
        
        if (result != wordAddr) {
            throw "could not commit page " + pageAddr;
        }
        
        pollUntilReady();
    }

    // Derived from https://github.com/adafruit/Standalone-Arduino-AVR-ISP-programmer/blob/master/code.cpp    
    function spiTransaction(b0, b1 = 0, b2 = 0, b3 = 0) {
        local out = blob(4);
        
        out.writen(b0, 'b');
        out.writen(b1, 'b');
        out.writen(b2, 'b');
        out.writen(b3, 'b');
        
        local r = spi.writeread(out);
        
        // Note: oddly the Adafruit code tries to return 3 bytes in 16 bits.
        return  0xFFFF & ((r[2] << 8) + r[3]);
    }

    function chipErase() {
        server.log("Info: erasing chip");

        program(PROGRAM_ENABLE, CHIP_ERASE, 0, 0);
        pollUntilReady();
    }
    
    function readPage(hexData, pageAddr, page) {
        local nextPageAddr = pageAddr + page.len();
        local blank = true;

        while (!hexData.eos()) {
            local pos = hexData.tell();
            local line = readLine(hexData);
            
            if (line.addr >= nextPageAddr) {
                // Rewind for rereading in next call to this function.
                hexData.seek(pos);
                break;
            }
            
            if (line.type == HEX_TYPE_END) {
                break;
            }
            
            if (line.len == 0) {
                continue;
            }
            
            local pageOffset = line.addr - pageAddr;
            
            if (pageOffset + line.len > page.len()) {
                throw "HEX data overflows page boundary"
            }
            
            if (blank) {
                blankPage(page);
                blank = false;
            }
            
            page.seek(pageOffset);
            page.writeblob(line.data);
        }
        
        page.seek(0);

        return !blank;
    }
    
    function blankPage(page) {
        page.seek(0);
        
        while (!page.eos()) {
            page.writen(0xff, 'b');
        }
        
        page.seek(0);
    }
    
    function readLine(hexData) {
        local line = { };
        
        line.addr <- hexData.readn('w');
        line.type <- hexData.readn('b');
        line.len <- hexData.readn('b');
        
        if (line.len > 0) {
            line.data <- hexData.readblob(line.len);
        }
        
        return line;
    }

    function startProgramming() {
        local confirm;
        local count = 0;

        // Adafruit don't bother with retrying.        
        do {
            count++;
            
            imp.sleep(0.1); // 100ms
            // TODO: Nick Gammon and Adafruit put SCLK low at this point.
            // Not doing so /seems/ to be OK - is it?
            reset.write(1);
            imp.sleep(0.001); // 1ms
            reset.write(0);
            imp.sleep(0.025); // 25ms
            
            confirm = spiTransaction(PROGRAM_ENABLE, PROGRAM_ACK) >> 8;
        } while (confirm != PROGRAM_ACK);
        
        server.log("Info: entered programming mode after " + count + " attempts");
    }
    
    function endProgramming() {
        reset.write(1);
    }
    
    function program(b0, b1 = 0, b2 = 0, b3 = 0, offset = 3) {
        local out = blob(4);
        
        out.writen(b0, 'b');
        out.writen(b1, 'b');
        out.writen(b2, 'b');
        out.writen(b3, 'b');
        
        return spi.writeread(out)[offset];
    }
    
    function program2(s, offset = 3) {
        return program(s[0], s[1], 0, 0, offset);
    }
    
    function byteToString(b) {
        return format("0x%02x", b);
    }
    
    function pollUntilReady() {
        local POLL_READY = 0xF0;
        local count = 0;
        local start = hardware.micros();
        
        // TODO: some MCUs apparently don't support POLL_READY. The families containing
        // the 328 and the ATtinyX5s both support POLL_READY. To check for a different
        // family look for the "Serial Programming Instruction Set" table in the MCUs
        // datasheet - one should find Poll RDY. If not one should simply wait here for
        // the time given for WD_FLASH in the datasheet. Nick Gammon waits 10ms in
        // https://github.com/nickgammon/arduino_sketches/blob/master/Atmega_Board_Programmer/Atmega_Board_Programmer.ino
        while ((program(POLL_READY) & 0x01) != 0x00) {
            count++;
        }
        
        local diff = hardware.micros() - start;
        server.log("Info: polled " + count + " times over " + diff + "us");
    }

    //TODO: find out why the following doesn't work:
    //const foo = "\xAC\x53\x00\x00";
    //spi.write(foo[0]);
    //spi.write(foo[1]);
    // //spi.write(foo[0].tostring());
    // //spi.write(foo[1].tostring());
    //confirm = spi.writeread("\x00")[0]; // Surely simply "\x00" should work?
    //spi.write("\x00");
}

class InSystemProgrammer189 extends InSystemProgrammer {
    constructor(_reset) {
        spi = hardware.spi189;
        reset = _reset;
        
        base.constructor();
    }
}
// -----------------------------------------------------------------------------
// End - In-System Programmer library
// -----------------------------------------------------------------------------

programmer <- InSystemProgrammer189(hardware.pin2);

showMemory(); // Show free memory on completing startup.
