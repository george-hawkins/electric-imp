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
}

function setLockBits(data) {
    local lockBits = data.lockBits;
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

// A HEX blob can eat up the Imp's memory - log free memory to spot issues.
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
class InSystemProgrammer {
    SPICLK = 250; // 250KHz - slow enough for processors like the ATtiny.
    PROGRAM_ENABLE = "\xAC\x53";
    READ_SIGNATURE = 0x30;
    READ_LOW_FUSE = 0x50;
    READ_EXTENDED_FUSE = "\x50\x08";
    READ_HIGH_FUSE = "\x58\x08";
    READ_LOCK = 0x58;
    
    HEX_TYPE_END = 0x01;

    spi = null;
    sclk = null;
    mosi = null;
    miso = null;
    reset = null;

    constructor() {
        // For unknown reasons these pins must be configured before spi.
        // Configure spi first and we cannot enter programming mode.
        sclk.configure(DIGITAL_OUT);
        mosi.configure(DIGITAL_OUT);
        reset.configure(DIGITAL_OUT);
        
        // I've confirmed MSB_FIRST and CLOCK_IDLE_LOW are the values used by the Arduino programmer by
        // printing out SPCR and decoding it using http://avrbeginners.net/architecture/spi/spi.html
        local speed = spi.configure((MSB_FIRST | CLOCK_IDLE_LOW), SPICLK);
        
        server.log("speed: " + speed + "KHz");
    }
    
    function run(action) {
        startProgramming();
        
        local result = action();

        endProgramming();
        
        return result;
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
                lfuse = program(READ_LOW_FUSE)
                hfuse = program2(READ_HIGH_FUSE)
                efuse = program2(READ_EXTENDED_FUSE)
            };
        });
    }
    
    function getLockBits() {
        return run(function() {
            return program(READ_LOCK);
        });
    }
    
    function uploadHex(part, hexData) {
        return run(function() {
            local chipSize = part.memories.flash.size;
            local page = blob(part.memories.flash.page_size);
            local pageAddr = 0;
            
            chipErase();

            server.log("pagesize=" + part.memories.flash.page_size);    
            local pagemask = ~(page.len() - 1);
            server.log(format("mask 0x%04x", pagemask));
            local oldM = 0;
            local oldAddr = 0;

            for (local i = 0; i < 0x400; i++) {
                local thisM = i & pagemask;
                
                if (thisM != oldM) {
                    server.log(format("commit 0x%04x 0x%04x", oldAddr, oldM));
                    oldAddr = i;
                    oldM = thisM;
                }
            }
            
            while (pageAddr < chipSize) {
                if (readPage(hexData, pageAddr, page)) {
//                    flashPage(pageAddr, page);
                    xFlashPage(pageAddr, page);
                }

                pageAddr += page.len();
            }
        });
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
    
    function xFlashWord(hilo, addr, data) {
        spiTransaction(0x40+8*hilo, addr>>8 & 0xff, addr & 0xff, data);
    }
    
    function xFlashPage(pageaddr, pagebuff) {
        // CLOCK SPEED???
        dumpPage(pageaddr, pagebuff);

        for (local i = 0; i < pagebuff.len() / 2; i++) {
            xFlashWord(0, i, pagebuff.readn('b'));
            xFlashWord(1, i, pagebuff.readn('b'));
        }
        
        server.log(format("new 0x%04x, old 0x%04x", (pageaddr >> 1), ((pageaddr / 2) & 0xFFC0)));

        pageaddr = pageaddr >> 1; // Word address.

        // pageaddr = (pageaddr / 2) & 0xFFC0;
        
        local commitreply = spiTransaction(0x4C, (pageaddr >> 8) & 0xff, pageaddr & 0xff, 0);
        
        if (commitreply != pageaddr) {
            throw commitreply + " != " + pageaddr;
        }
        
        pollUntilReady();
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
        local wordAddr = (pageAddr / 2) & 0xFFC0;
        local addrHigh = wordAddr >> 8 & 0xFF;
        local addrLow = wordAddr & 0xFF;
        
        server.log(format("XXX%d commit 0x%04x 0x%02x 0x%02x", i++, wordAddr, addrHigh, addrLow));
        local result = spiTransaction(0x4C, addrHigh, addrLow, 0);
        
        server.log(format("XXX%d 0x%06x", i++, result))
        
        if (result != wordAddr) {
            throw "could not commit page to " + pageAddr;
        }
        
        pollUntilReady();
    }

    // Derived from https://github.com/adafruit/Standalone-Arduino-AVR-ISP-programmer/blob/master/code.cpp    
    function spiTransaction(b0, b1 = 0, b2 = 0, b3 = 0, offset = 3) {
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
        local CHIP_ERASE = 0x80;
        programWrite(CHIP_ERASE);
        pollUntilReady();
    }
    
    function readPage(hexData, pageAddr, page) {
        blankPage(page);
        
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
            
            page.seek(pageOffset);
            page.writeblob(line.data);
            blank = false;
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
            sclk.write(0);
            reset.write(1);
            imp.sleep(0.001); // 1ms
            reset.write(0);
            imp.sleep(0.025); // 25ms
            
            confirm = program2(PROGRAM_ENABLE, 2);
        } while (confirm != PROGRAM_ENABLE[1]);
        
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
    
    // TODO: can PROGRAM_ENABLE use this?
    // TODO: will anything other than CHIP_ERASE use this? If not remove.
    function programWrite(b1) {
        program(0xAC, b1, 0, 0);
    }

    function byteToString(b) {
        return format("0x%02x", b);
    }
    
    function writeSketch() {
        chipErase();
        
        server.log("Info: writing pages...");
        
        // THE ADAFRUIT SKETCH CAN DEAL WITH ORIGINAL .hex FILES WITH "\n" ADDED
        // TO EACH LINE. AND IT DOES SOME FUSE PROGRAMMING THAT SEEMS TO BE
        // MISSING HERE. HOWEVER I WONDER IF IT DOES TOO MUCH FUSE PROGRAMMING.
        // IF YOU LOOK IN
        // /Applications/Arduino.app/Contents/Resources/Java/hardware/arduino/boards.txt
        // PROBABLY JUST THE LOCK BITS NEED TO SET/UNSET.
        // AND IF YOU LOOK AT https://code.google.com/p/arduino/wiki/Platforms IT SEEMS
        // THOSE ARE ONLY NEEDED FOR WHEN BURNING A BOOTLOADER.
        // The contents of
        // http://svn.savannah.nongnu.org/viewvc/*checkout*/trunk/avrdude/avrdude.conf.in?root=avrdude
        // look more useful that boards.txt - it covers more boards and includes more details (signatures etc).
        
        // for (local i = 0; i < len; i += 2) {
        //     local currentPage = (addr + i) & pagemask;
            
        //     if (currentPage != oldPage) {
        //         commitPage(oldPage);
        //         oldPage = currentPage;
        //     }
            
        //     writeFlash(addr + i, sketch[i]);
        //     writeFlash(addr + i + 1, sketch[i + 1]);
        // }
        
        // commitPage(oldPage);
        
        server.log("Info: completed");
        // for (i = 0; i < len; i += 2)
        //   {
        //   unsigned long thisPage = (addr + i) & pagemask;
        //   // page changed? commit old one
        //   if (thisPage != oldPage)
        //     {
        //     commitPage (oldPage);
        //     oldPage = thisPage;
        //     }  
        //   writeFlash (addr + i, pgm_read_byte(bootloader + i));
        //   writeFlash (addr + i + 1, pgm_read_byte(bootloader + i + 1));
        //   }  // end while doing each word
          
        // // commit final page
        // commitPage (oldPage);
        // Serial.println ("Written.");
        // }
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
        sclk = hardware.pin1;
        mosi = hardware.pin8;
        miso = hardware.pin9;
        reset = _reset;
        
        base.constructor();
    }
}
// -----------------------------------------------------------------------------
// End - In-System Programmer library
// -----------------------------------------------------------------------------

programmer <- InSystemProgrammer189(hardware.pin2);

showMemory(); // Show free memory on completing startup.
