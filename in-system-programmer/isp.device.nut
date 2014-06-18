// TODO: add in SpiProgrammer.

// Tables don't support plus or append(...).
function merge(src, dest) {
    foreach (slot, value in src) {
        dest[slot] <- value;
    }
}

function getSignature() {
    return [ 0x1e, 0x94, 0x03 ];
}

function getFuses() {
    return {
        lfuse = 0x62
        hfuse = 0xdf
        efuse = 0xff
    };
}

function setFuses(data) {
    local lfuse = data.lfuse;
    local hfuse = data.hfuse;
    local efuse = data.efuse;
}

function getLockBits() {
    return 0xff;
}

function setLockBits(data) {
    local lockBits = data.lockBits;
}

function uploadHex(data) {
    // Unlike elsewhere the items, due to their size, are deleted in order
    // to avoid sending them back in the response.
    local hexData = delete data.hexData;
    local part = delete data.part;
    
    decodeProgram(hexData);
}

function decodeProgram(program) {
    server.log("Info: free memory=" + imp.getmemoryfree() + "B");
    
    local count = 0;
    
    while (!program.eos()) {
        local addr = program.readn('w');
        local type = program.readn('b');
        local len = program.readn('b');
        if (len > 0) {
            local data = program.readblob(len);
        }
        count++;
    }
    
    server.log("Info: read " + count + " program lines");
}

function handleActionSendImpl(data) {
    try {
        switch (data.action) {
        case "getSignature":
            data.signature <- getSignature();
            break;
        case "getFuses":
            merge(getFuses(), data);
            break;
        case "setFuses":
            setFuses(data);
            break;
        case "getLockBits":
            data.lockBits <- getLockBits();
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

function dispatchActionSend(data) {
    handleActionSend(data);
}

agent.on("actionSend", dispatchActionSend);
