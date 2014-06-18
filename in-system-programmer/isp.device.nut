// TODO: pull together this, IntelHexParser and SpiProgrammer.

function handleActionSendImpl(data) {
    try {
        switch (data.action) {
        case "getSignature":
            data.signature <- [ 0x1e, 0x93, 0x07 ];
            break;
        case "getFuses":
            data.lfuse <- 0x62;
            data.hfuse <- 0xdf;
            data.efuse <- 0xff;
            break;
        case "setFuses":
            break;
        case "getLockBits":
            data.lockBits <- 0xff;
            break;
        case "setLockBits":
            break;
        case "uploadHex":
            // Large items are deleted to avoid sending them in response.
            local hexData = delete data.hexData;
            local part = delete data.part;
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
