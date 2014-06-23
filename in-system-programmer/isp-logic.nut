// TODO: REMOVE - this is just here temporarily as a record of the original WORKING logic.

class InSystemProgrammer {
    SPICLK = 250; // 250KHz - slow enough for processors like the ATtiny.
    PROGRAM_ENABLE = "\xAC\x53";
    READ_SIGNATURE = 0x30;
    READ_LOW_FUSE = 0x50;
    READ_EXTENDED_FUSE = "\x50\x08";
    READ_HIGH_FUSE = "\x58\x08";
    READ_LOCK = 0x58;

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
    
    function uploadHex() {
        return run(function() {
            writeSketch();
        });
    }
    
    function go() {
        local s = getSignature();
        
        server.log("Info: found MCU " + format("0x%02x%02x%02x", s[0], s[1], s[2]));

        local fuses = getFuses();
        
        server.log("Info: low-fuse=" + byteToString(fuses.lfuse));
        server.log("Info: high-fuse=" + byteToString(fuses.hfuse));
        server.log("Info: extended-fuse=" + byteToString(fuses.efuse));
        
        server.log("Info: lock=" + byteToString(getLockBits()));
        
        uploadHex();

        server.log("Info: finished");
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
    function programWrite(b1) {
        program(0xAC, b1, 0, 0);
    }

    function byteToString(b) {
        return format("0x%02x", b);
    }
    
    function writeSketch() {
        server.log("Info: erasing chip");
        local CHIP_ERASE = 0x80;
        programWrite(CHIP_ERASE);
        imp.sleep(0.02); // For ATmega8.
        pollUntilReady();
        
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

programmer <- InSystemProgrammer189(hardware.pin2);

programmer.go();

