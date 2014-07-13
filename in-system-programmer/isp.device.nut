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
 
// Handle all the actions sent by the agent.
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
            programmer.setLockBits(data.lockBits);
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
        server.log(ex);
    }
}

handleActionSend <- handleActionSendImpl;

// Using the "test" action one can flip the handler between the real one and
// this one in order to test the agent logic for failure handling.
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

// Two degrees of indirection - handleActionSend is a variable.
function dispatchActionSend(data) {
    handleActionSend(data);
}

agent.on("actionSend", dispatchActionSend);

function setFuses(data) {
    programmer.setFuses(
        data.lfuse,
        data.hfuse,
        data.efuse,
        data.unsafe);
}

function uploadHex(data) {
    showMemory(); // Log how the HEX blob impacted memory.
    
    // Unlike elsewhere the items, due to their size, are deleted in order
    // to avoid sending them back in the response.
    local hexData = HexData(delete data.part, delete data.hexData);

    programmer.uploadHex(hexData);
}

// Tables don't support plus or append(...).
function merge(src, dest) {
    foreach (slot, value in src) {
        dest[slot] <- value;
    }
}

function showMemory() {
    server.log("free memory=" + imp.getmemoryfree() + "B");
}

// -----------------------------------------------------------------------------
// Start - In-System Programmer library
// -----------------------------------------------------------------------------
class InSystemProgrammer {
    static SPICLK = 250; // 250KHz - slow enough for even 1MHz processors.

    static READ_SIGNATURE = 0x30000000;
    
    static READ_FLASH_LO = 0x20000000;
    static READ_FLASH_HI = 0x28000000;
    static WRITE_FLASH_LO = 0x40000000;
    static WRITE_FLASH_HI = 0x48000000;
    
    static COMMIT_PAGE = 0x4C000000;
    
    static CHIP_ERASE = 0xAC800000;

    static PROG_ENABLE = 0xAC530000;
    static PROG_ACK = 0x5300;

    static POLL_READY = 0xF0000000;

    // Most actions take a few milliseconds so 1s is a generous retry timeout.
    static RETRY_TIMEOUT = 1000000;
    
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
    
    function getSignature() {
        return run(function() {
            return [
                spiSend(READ_SIGNATURE | 0x0000),
                spiSend(READ_SIGNATURE | 0x0100),
                spiSend(READ_SIGNATURE | 0x0200)
            ];
        });
    }
    
    function getFuses() {
        return run(function() {
            return {
                lfuse = fuses.getLfuse()
                hfuse = fuses.getHfuse()
                efuse = fuses.getEfuse()
            };
        });
    }
    
    function setFuses(lfuse, hfuse, efuse, unsafe) {
        run(function() {
            fuses.setLfuse(lfuse, unsafe);
            fuses.setHfuse(hfuse, unsafe);
            fuses.setEfuse(efuse);
        });
    }

    function getLockBits() {
        return run(function() {
            return fuses.getLockBits();
        });
    }
    
    function setLockBits(lockBits) {
        run(function() {
           fuses.setLockBits(lockBits);
        });
    }

    function uploadHex(hexData) {
        return run(function() {
            chipErase();

            local page;

            while ((page = hexData.readPage()) != null) {
                writeFlashPage(page);
            }

            hexData.reset()
            verifyImage(hexData);
        });
    }

    function verifyImage(hexData) {
        local line;

        while ((line = hexData.readDataLine()) != null) {
            local wordAddr = line.addr >> 1;
            local data = line.data;
            
            // We expect pairs of bytes, i.e. 16 bit words.
            if (data.len() % 2 != 0) {
                throw format("line 0x04x does not end on a word boundary", line.addr);
            }
            
            while (!data.eos()) {
                verifyFlashByte(READ_FLASH_LO, wordAddr, data.readn('b'));
                verifyFlashByte(READ_FLASH_HI, wordAddr, data.readn('b'));
                wordAddr++;
            }
        }
    }
    
    function verifyFlashByte(command, wordAddr, expected) {
        local actual = spiSend(addWordAddr(command, wordAddr));
        
        if (actual != expected) {
            // IMPORTANT: the address shown in this exception is the *word* address.
            throw format("expected 0x%02x but found 0x%02x at word-address 0x%04x",
                expected, actual, wordAddr)
        }
    }
    
    function writeFlashPage(page) {
        local wordOffset = 0;
        
        while (!page.data.eos()) {
            writeFlashByte(WRITE_FLASH_LO, wordOffset, page.data.readn('b'));
            writeFlashByte(WRITE_FLASH_HI, wordOffset, page.data.readn('b'));
            wordOffset++;
        }
        
        commitPage(page.addr);
    }
    
    function writeFlashByte(command, wordAddr, b) {
        spiSend(addWordAddr(command, wordAddr) | b);
    }
    
    function commitPage(pageAddr) {
        // Note: if comparing with Adafruit and Nick Gammon - a mask is not needed
        // here as the passed in address is known to the be the start of a page.
        
        local wordAddr = pageAddr >> 1;
        local command = addWordAddr(COMMIT_PAGE, wordAddr);

        if (spiSend(command, 0xFFFF) != wordAddr) {
            throw "could not commit page " + pageAddr;
        }

        pollUntilReady();
    }
    
    function addWordAddr(command, wordAddr) {
        return command | (wordAddr << 8);
    }

    function chipErase() {
        server.log("erasing chip");

        spiSend(CHIP_ERASE);
        pollUntilReady();
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
    
    function startProgramming() {
        // Adafruit doesn't bother with retrying.        
        retry("start-promgramming", function () {
            imp.sleep(0.1); // 100ms
            // TODO: Nick Gammon and Adafruit put SCLK low at this point.
            // Not doing so /seems/ to be OK - is it?
            reset.write(1);
            imp.sleep(0.001); // 1ms
            reset.write(0);
            imp.sleep(0.025); // 25ms
            
            return spiSend(PROG_ENABLE, 0xff00) == PROG_ACK;
        });
    }
    
    function endProgramming() {
        reset.write(1);
    }

    // Some MCUs don't support POLL_READY. For these cases it would be necessary
    // to wait the delay defined by part.memories.flash.min_write_delay
    function pollUntilReady() {
        retry("poll-until-ready", function () {
            return (spiSend(POLL_READY) & 0x01) == 0x00;
        });
    }

    function retry(name, action) {
        local count = 1;
        local start = hardware.micros();
        local diff = -1;
        local success;
        
        while (diff < RETRY_TIMEOUT && !(success = action())) {
            diff = hardware.micros() - start;
            count++;
        }
        
        if (!success) {
            throw name + " did not succeed after " + count + " attempts";
        } else if (count > 1) {
            server.log(name + " succeeded after " + count + " attempts and " +
                (diff > 1000 ? (diff / 1000) + "ms" : diff + "us"));
        }
    }

    function spiSend(i, mask = 0xff) {
        local out = blob(4);
        
        out.writen(i, 'i');
        out.swap4();
        
        local result = spi.writeread(out);

        result.swap4();

        return result.readn('i') & mask;
    }
}

class InSystemProgrammer189 extends InSystemProgrammer {
    constructor(_reset) {
        spi = hardware.spi189;
        reset = _reset;
        
        base.constructor();
    }
}

class Fuses {
    static WRITE_LOCKBITS = 0xACE00000;
    static WRITE_LFUSE    = 0xACA00000;
    static WRITE_HFUSE    = 0xACA80000;
    static WRITE_EFUSE    = 0xACA40000;
    static READ_LOCKBITS  = 0x58000000;
    static READ_LFUSE     = 0x50000000;
    static READ_HFUSE     = 0x58080000;
    static READ_EFUSE     = 0x50080000;

    // Inspired by Nut's AvrTargetFusesWriteSafe.
    // http://sourceforge.net/p/ethernut/code/5726/tree/trunk/nut/dev/avrtarget.c
    // In contrast to Nut CKOUT is viewed as safe here and DWEN as dangerous (as it clearly disables ISP).
    // These values only provide (some degree of safety) for ATmega and ATtiny MCUs.
    // Other AVRs have different fuse bit assignments.
    static LFUSE_SAFE = 0xC0; // CKDIV8, CKOUT
    static HFUSE_SAFE = 0x1F; // WDTON, EESAVE, boot loader bits (ATmega), brown-out bits (ATtiny).

    parent = null;

    constructor(_parent) {
        parent = _parent;
    }
    
    function getLfuse() { return parent.spiSend(READ_LFUSE); }
    
    function getHfuse() { return parent.spiSend(READ_HFUSE); }
    
    function getEfuse() { return parent.spiSend(READ_EFUSE); }
    
    function getLockBits() { return parent.spiSend(READ_LOCKBITS); }

    function safe(name, newValue, oldValue, safeBits) {
        local unsafeBits = ~safeBits;
        
        // If new value would change any unsafe bits...
        if ((newValue & unsafeBits) != (oldValue & unsafeBits))
            throw format("0x%02x would change unsafe bits of %s", newValue, name);

        return true;
    }
    
    function setFuse(name, writeCmd, newValue, oldValue,
        allowUnsafe = false, safeBits = 0xFF) {

        if (newValue != oldValue) {
            if (allowUnsafe || safe(name, newValue, oldValue, safeBits)) {
                parent.spiSend(writeCmd | newValue);
                parent.pollUntilReady();
            }
        }
    }
    
    function setLfuse(value, allowUnsafe) {
        setFuse("lfuse", WRITE_LFUSE, value, getLfuse(), allowUnsafe, LFUSE_SAFE);
    }
    
    function setHfuse(value, allowUnsafe) {
        setFuse("hfuse", WRITE_HFUSE, value, getHfuse(), allowUnsafe, HFUSE_SAFE);
    }
    
    function setEfuse(value) {
        setFuse("efuse", WRITE_EFUSE, value, getEfuse());
    }
    
    function setLockBits(value) {
        local oldValue = getLockBits();
        
        if ((value & ~oldValue) != 0) {
            throw "programmed lock bits can only be reset with chip erase";
            // The simplest way to erase the chip is to upload an image.
        }
        setFuse("lockBits", WRITE_LOCKBITS, value, oldValue);
    }
}

class HexData {
    static TYPE_DATA = 0x00;
    static EMPTY_BLOB = blob(0);

    data = null;
    page = null;
    pageMask = 0;

    constructor(part, _data) {
        data = _data;

        page = blob(part.memories.flash.page_size);
        pageMask = ~(page.len() - 1);
        // The page mask calculation comes from Nick Gammon. Adafruit hardcode a mask that's
        // only suitable for the 128B page size of the ATMega16 and ATMega32 famalies.
    }

    function reset() {
        data.seek(0);
    }

    function readPage() {
        local line = readDataLine();

        if (line == null) return null;

        data.seek(line.pos); // Undo line read.

        clearPage(page);

        local pageAddr = getPageAddr(line.addr);
        local nextPageAddr = pageAddr + page.len();

        while ((line = readDataLine()) != null) {
            if (line.addr >= nextPageAddr) {
                data.seek(line.pos); // Undo line read.
                break;
            }
            
            local pageOffset = line.addr - pageAddr;
            
            if (pageOffset + line.data.len() > page.len()) {
                throw "HEX data overflows page boundary"
            }

            page.seek(pageOffset);
            page.writeblob(line.data);
        }
        
        page.seek(0);

        return {
            addr = pageAddr
            data = page
        };
    }

    function clearPage(page) {
        page.seek(0);
        
        while (!page.eos()) {
            page.writen(0xff, 'b');
        }
        
        page.seek(0);
    }
    
    // Returns the start address of the page containing the given address.
    function getPageAddr(addr) {
        return addr & pageMask;
    }

    function readDataLine() {
        local line;
        
        while ((line = readLine()) != null) {
            if (line.type != TYPE_DATA) {
                return null; // Ignore everything beyond the first non-data line.
            } else if (line.data.len() > 0) {
                break;
            }
        }
        
        return line;
    }

    function readLine() {
        if (data.eos()) {
            return null;
        }

        local len;

        return { 
            pos = data.tell()
            addr = data.readn('w')
            type = data.readn('b')
            data = (len = data.readn('b')) > 0 ? data.readblob(len) : EMPTY_BLOB
        };
    }
}
// -----------------------------------------------------------------------------
// End - In-System Programmer library
// -----------------------------------------------------------------------------

programmer <- InSystemProgrammer189(hardware.pin2);

// Respond to agent send-if-responding logic.
agent.on("ping", function(key) { agent.send("pong", key); });

showMemory(); // Show free memory on completing startup.

server.log("device ready");
