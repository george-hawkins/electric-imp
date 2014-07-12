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
    // TODO: stick "static" in front of all "constants".
    // TODO: standardize on command rather than instruction, image rather than sketch/Hex?
    WRITE_LOCK  = 0xACE00000;
    WRITE_LFUSE = 0xACA00000;
    WRITE_HFUSE = 0xACA80000;
    WRITE_EFUSE = 0xACA40000;
    READ_LOCK   = 0x58000000;
    READ_LFUSE  = 0x50000000;
    READ_HFUSE  = 0x58080000;
    READ_EFUSE  = 0x50080000;

    // Inspired by Nut's AvrTargetFusesWriteSafe.
    // http://sourceforge.net/p/ethernut/code/5726/tree/trunk/nut/dev/avrtarget.c
    // In contrast to Nut CKOUT is viewed as safe here and DWEN as dangerous (as it clearly disables ISP).
    // These values only provide (some degree of safety) for ATmega and ATtiny AVRs.
    // Other AVRs have different fuse bit assingments.
    LFUSE_SAFE = 0xC0; // CKDIV8, CKOUT
    HFUSE_SAFE = 0x1F; // WDTON, EESAVE, boot loader bits (ATmega), brown-out bits (ATtiny).
    parent = null;

    constructor(_parent) {
        parent = _parent;
    }
    
    function readLfuse() { return parent.xxx(READ_LFUSE); }
    
    function readHfuse() { return parent.xxx(READ_HFUSE); }
    
    function readEfuse() { return parent.xxx(READ_EFUSE); }
    
    function readLock() { return parent.xxx(READ_LOCK); }

    function safe(name, newValue, oldValue, safeBits) {
        local unsafeBits = ~safeBits;
        
        // If new value would change any unsafe bits...
        if ((newValue & unsafeBits) != (oldValue & unsafeBits))
            throw format("0x%02x would change unsafe bits of %s", newValue, name);

        return true;
    }
    
    function writeFuse(name, writeCmd, newValue, oldValue,
        allowUnsafe = false, safeBits = 0xFF) {

        if (newValue != oldValue) {
            if (allowUnsafe || safe(name, newValue, oldValue, safeBits)) {
                parent.xxx(writeCmd | newValue);
                parent.pollUntilReady();
            }
        }
    }
    
    function writeLfuse(value, allowUnsafe) {
        writeFuse("lfuse", WRITE_LFUSE, value, readLfuse(), allowUnsafe, LFUSE_SAFE);
    }
    
    function writeHfuse(value, allowUnsafe) {
        writeFuse("hfuse", WRITE_HFUSE, value, readHfuse(), allowUnsafe, HFUSE_SAFE);
    }
    
    function writeEfuse(value) {
        writeFuse("efuse", WRITE_EFUSE, value, readEfuse());
    }
    
    function writeLock(value) {
        local oldValue = readLock();
        
        if ((value & ~oldValue) != 0) {
            throw "programmed lock bits can only be reset with chip erase";
            // The simplest way to erase the chip is to upload an image.
        }
        writeFuse("lockBits", WRITE_LOCK, value, oldValue);
    }
}

class InSystemProgrammer {
    SPICLK = 250; // 250KHz - slow enough for even 1MHz processors.

    HEX_TYPE_END = 0x01;

    spi = null;
    reset = null;
    fuses = null;

    constructor() {
        fuses = Fuses(this);
        
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
    
    READ_SIGNATURE = 0x30000000;
    
    function getSignature() {
        return run(function() {
            return [
                xxx(READ_SIGNATURE | 0x0000),
                xxx(READ_SIGNATURE | 0x0100),
                xxx(READ_SIGNATURE | 0x0200)
            ];
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
            fuses.writeLfuse(lfuse, false);
            fuses.writeHfuse(hfuse, false);
            fuses.writeEfuse(efuse);
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
                    writeFlashPage(pageAddr, page);
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
            
            local wordAddr = line.addr >> 1;
            local data = line.data;
            
            // We expect pairs of bytes, i.e. 16 bit words.
            if (data.len() % 2 != 0) {
                throw format("line 0x04x doesn't end on a word boundary", line.addr);
            }
            
            while (!data.eos()) {
                verifyFlashByte(READ_FLASH_LO, wordAddr, data.readn('b'));
                verifyFlashByte(READ_FLASH_HI, wordAddr, data.readn('b'));
                wordAddr++;
            }
        }
    }
    
    function verifyFlashByte(command, wordAddr, expected) {
        local actual = xxx(addWordAddr(command, wordAddr));
        
        if (actual != expected) {
            // IMPORTANT: the address used here is the *word* address.
            throw format("expected 0x%02x but found 0x%02x at word-address 0x%04x",
                expected, actual, wordAddr)
        }
    }
    
    READ_FLASH_LO = 0x20000000;
    READ_FLASH_HI = 0x28000000;

    function writeFlashPage(pageAddr, page) {
        local wordOffset = 0;
        
        while (!page.eos()) {
            writeFlashByte(WRITE_FLASH_LO, wordOffset, page.readn('b'));
            writeFlashByte(WRITE_FLASH_HI, wordOffset, page.readn('b'));
            wordOffset++;
        }
        
        commitPage(pageAddr);
    }
    
    WRITE_FLASH_LO = 0x40000000;
    WRITE_FLASH_HI = 0x48000000;
    
    function writeFlashByte(command, wordAddr, b) {
        xxx(addWordAddr(command, wordAddr) | b);
    }
    
    function addWordAddr(command, wordAddr) {
        return command | (wordAddr << 8);
    }

    COMMIT_PAGE = 0x4C000000;
    
    function commitPage(pageAddr) {
        
        // Note: both Adafruit and Nick Gammon AND the address with a mask.
        // This is only necessary to get the start of page address for an arbitrary address.
        // Here the passed in address is always the start of a page.
        // If you do need a mask then it must be calculated according to the page size:
        //   local mask = ~(page.len() - 1)
        // Nick Gammon handles this correctly - Adafruit hardcode for the 128 byte page
        // size of the ATMega16 and ATMega32 famalies.
        
        local wordAddr = pageAddr >> 1;
        local command = addWordAddr(COMMIT_PAGE, wordAddr);

        if ((xxx(command, -1) & 0xFFFF) != wordAddr) {
            throw "could not commit page " + pageAddr;
        }

        pollUntilReady();
    }

    CHIP_ERASE = 0xAC800000;
    
    function chipErase() {
        server.log("Info: erasing chip");

        xxx(CHIP_ERASE);
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

    PROG_ENABLE = 0xAC530000;
    PROG_ACK = 0x53; // 3rd byte of PROG_ENABLE
    
    // TODO: put limit on looping, i.e. retrying.
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
            
            confirm = xxx(PROG_ENABLE, 2);
        } while (confirm != PROG_ACK);
        
        server.log("Info: entered programming mode after " + count + " attempts");
    }
    
    function endProgramming() {
        reset.write(1);
    }

    POLL_READY = 0xF0000000;

    // TODO: put limit on looping, i.e. retrying.
    function pollUntilReady() {
        local count = 1;
        local start = hardware.micros();
        
        // Some MCUs don't support POLL_READY. For these cases it would be necessary
        // to wait the delay defined by part.memories.flash.min_write_delay
        while ((xxx(POLL_READY) & 0x01) != 0x00) {
            count++;
        }
        
        local diff = hardware.micros() - start;
        server.log("Info: polled " + count + " times over " + diff + "us");
    }

    // TODO: should -1 be default offset? And should swap4() always be applied and
    // offset adjusted accordingly?
    // TODO: rename to spiCommand, spiSend, spiTransaction ???
    function xxx(i, offset = 3) {
        local out = blob(4);
        
        out.writen(i, 'i');
        out.swap4();
        
        local result = spi.writeread(out)

        if (offset == -1) {
            result.swap4();
            return result.readn('i');
        } else {
            return result[offset];
        }
    }
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

// Respond to Agent pinger logic.
agent.on("ping", function(data) { agent.send("pong", null); });

showMemory(); // Show free memory on completing startup.
