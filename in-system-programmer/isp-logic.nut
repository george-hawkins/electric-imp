// TODO: REMOVE - this is just here temporarily as a record of the original WORKING logic.

const SPICLK = 250; // 250KHz - slow enough for processors like the ATtiny.
const PROGRAM_ENABLE = "\xAC\x53";
const READ_SIGNATURE = 0x30;
const READ_LOW_FUSE = 0x50;
const READ_EXTENDED_FUSE = "\x50\x08";
const READ_HIGH_FUSE = "\x58\x08";
const READ_LOCK = 0x58;
const READ_CALIBRATION = 0x38;

// reset <- hardware.pin8;
// spi <- hardware.spi257;
// miso <- hardware.pin2;
// sclk <- hardware.pin5;
// mosi <- hardware.pin7;

reset <- hardware.pin2;
spi <- hardware.spi189;
sclk <- hardware.pin1;
mosi <- hardware.pin8;
miso <- hardware.pin9;


sclk.configure(DIGITAL_OUT);
mosi.configure(DIGITAL_OUT);
reset.configure(DIGITAL_OUT);

function setup() {
    reset.write(1);
    
    // MSB_FIRST and CLOCK_IDLE_LOW have been confirmed as the values used in the
    // Arduino programmer by printing out SPCR and decoding it using http://avrbeginners.net/architecture/spi/spi.html
    local speed = spi.configure((MSB_FIRST | CLOCK_IDLE_LOW), SPICLK);
    
    server.log("speed: " + speed + "KHz");
}

function startProgramming() {
    
    local confirm;
    
    do {
        imp.sleep(0.1); // 100ms
        sclk.write(0);
        reset.write(1);
        imp.sleep(0.001); // 1ms
        reset.write(0);
        imp.sleep(0.025); // 25ms
        
        confirm = program2(PROGRAM_ENABLE, 2);
    } while (confirm != PROGRAM_ENABLE[1]);
    
    server.log("Info: entered programming mode");
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

// // I can't find an existing Squirrel function for this.
// function arrayEquals(a, b) {
//     if (a.len() != b.len()) {
//         return false;
//     }
    
//     foreach (i, value in a) {
//         if (b[i] != value) {
//             return false;
//         }
//     }
    
//     return true;
// }

function byteToString(b) {
    return format("0x%02x", b);
}

function byteArrayToString(array) {
    local result = "[";
    
    foreach (i, b in array) {
        if (i != 0) {
            result += ", ";
        }
        result += byteToString(b);
    }
    
    return result + "]";
}

class McuDetails {
    name = null;
    signature = null;
    flashBytes = null;
    
    constructor(_name, _signature, flashKb) {
        name = _name;
        signature = _signature;
        flashBytes = flashKb * 1024;
    }
    
    function signatureMatches(_signature) {
        // IMPORTANT: if you insert a line break between "return" and "_signature[0]"
        // Squirrel won't complain but you'll actually return nothing, i.e. it's
        // equivalent to "return;"
        return _signature[0] == 0x1E &&
            _signature[1] == signature[0] &&
            _signature[2] == signature[1];
    }
}

details <- [
    McuDetails("ATtiny25", "\x91\x08", 2),
    McuDetails("ATtiny45", "\x92\x06", 4),
    McuDetails("ATtiny85", "\x93\x0B", 8)
];

function getSignature() {
    local sig = [];
    
    for (local i = 0; i < 3; i++) {
        sig.append(program(READ_SIGNATURE, 0, i));
    
        server.log(sig[i]);
    }
    
    foreach (mcu in details) {
        if (mcu.signatureMatches(sig)) {
            return mcu;
        }
    }

    server.log("Error: could not find MCU with signature " + byteArrayToString(sig));
    return null;
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

function loop() {
    startProgramming();
    local mcu = getSignature();
    
    if (mcu == null) {
        return;
    }
    
    server.log("Info: found MCU " + mcu.name);
        
    server.log("Info: low-fuse=" + byteToString(program(READ_LOW_FUSE)));
    server.log("Info: high-fuse=" + byteToString(program2(READ_HIGH_FUSE)));
    server.log("Info: extended-fuse=" + byteToString(program2(READ_EXTENDED_FUSE)));
    server.log("Info: lock=" + byteToString(program(READ_LOCK)));
    server.log("Info: clock-calibration=" + byteToString(program(READ_CALIBRATION)));
    
    writeSketch();
    
    reset.write(1);
    
    server.log("Info: finished");
}

function dump(name, value) {
    server.log(name + " - value: \"" + value + "\", type: " + typeof value);
}

//test();
setup();
loop();

// function test() {
//     const x = "\xAC\x53";
//     local a = x[1];
//     local b = a.tostring();
//     local c = format("%c", 0x53);
//     local d = 'S';
//     local e = d.tostring();
//     local f = x.slice(1, 2);
//     local g = "S";
//     local h = "\x53";
    
//     dump("a", a);
//     dump("b", b);
//     dump("c", c);
//     dump("d", d);
//     dump("e", e);
//     dump("f", f);
//     dump("g", g);
//     dump("h", h);
// }

//TODO: find out why the following doesn't work:
//const foo = "\xAC\x53\x00\x00";
//spi.write(foo[0]);
//spi.write(foo[1]);
// //spi.write(foo[0].tostring());
// //spi.write(foo[1].tostring());
//confirm = spi.writeread("\x00")[0]; // Surely simply "\x00" should work?
//spi.write("\x00");
