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
 
function dumpTable(table, indent = ">") {
    foreach (key, value in table) {
        server.log(indent + key + " = " + value + " ");
        if (typeof value == "table") {
            if (value.len() == 0) {
                server.log(indent + "  // Empty.");
            } else {
                dumpTable(value, indent + "  ");
            }
        }
    }
}

const PROGRAMMER_PATH = "/programmer/";
const NO_TRAILING_SLASH = "/programmer"; // Can't use method call, e.g. slice(...), with const.
const ACTION_PATH = "/programmer/action/";

server.log("Programmer URL: " + http.agenturl() + PROGRAMMER_PATH);

// Retrieve this URL to toggle test mode on or off.
server.log("Test on/off URL: " + http.agenturl() + PROGRAMMER_PATH + "action/test");

function startsWith(a, b) {
    return a.len() >= b.len() && a.slice(0, b.len()) == b;
}

hexBytePattern <- regexp("0x[0-9a-fA-F][0-9a-fA-F]");

function getByteParam(request, name) {
    local s = request.query[name];
    
    if (!hexBytePattern.match(s)) {
        throw name + " should be a hex byte of form \"0xXY\" but was \"" + s + "\"";
    }
    
    return getByte(s, 2);
}

function getSetFusesParams(request) {
    return {
        lfuse = getByteParam(request, "lfuse")
        hfuse = getByteParam(request, "hfuse")
        efuse = getByteParam(request, "efuse")
    };
}

function getSetLockBitsParam(request) {
    return {
        lockBits = getByteParam(request, "lockBits")
    };
}

function getUploadHexParam(request) {
    local parts = parseMultipart(request);

    // TODO: allow part to be uploaded as a file too to allow  REST like
    // interaction, in addition to HTML form. Could do...
    // context.part = http.jsondecode(...) and check for this on imp side.
    return {
        hexData = parseIntelHex(parts["hexFile"].content)
    };
}

function getContent(url, headers = { }) {
    local request = http.get(url, headers);
    local response = request.sendsync();

    if (response.statuscode != 200) {
        throw response.statuscode + " - " + response.body;
    }

    return response.body;
}

// -----------------------------------------------------------------------------

// TODO: move content from pages-dev to Programmer repo.
const SRC_BASE_URL = "https://george-hawkins.github.io/pages-dev/";

function getIndex() {
    return getContent(SRC_BASE_URL + "index.html");
}

// -----------------------------------------------------------------------------

const SIGNATURE_URL = "https://avrdude-conf.herokuapp.com/conf/parts/signatures/";
ACCEPT_JSON <- { Accept = "application/json" }; // Only scalars can be consts.

partCache <- { };

function getPart(s) {
    local key = format("0x%02x%02x%02x", s[0], s[1], s[2]);
    local part;
    
    if (key in partCache) {
        part = partCache[key];
    } else {
        local url = SIGNATURE_URL + format("0x%02x%02x%02x", s[0], s[1], s[2]);
        
        part = http.jsondecode(getContent(url, ACCEPT_JSON));
        partCache[key] <- part;
    }
    
    return part;
}

// -----------------------------------------------------------------------------

class Context {
    data = null
    response = null
    constructor(_action, _response, _data = {}) {
        response = _response;
        data = _data;
        data.action <- _action;
        data.timestamp <- time(); // Note: only to nearest second.
    }

    function handleReply(_data, success) {
        try {
            (success ? handleSuccess : handleFailure)(_data);
        } catch (ex) {
            sendException(response, ex, data);
        }
    }
    
    function handleSuccess(_data) {
        data = _data;
        sendResponse(200);
    }
    
    function handleFailure(_data) {
        data = _data;
        sendResponse(500);
    }
    
    function sendResponse(code) {
        sendJson(code, response, data);
    }
}

const GET_SIGNATURE_ACTION = "getSignature";
const UPLOAD_HEX_ACTION = "uploadHex";

class SignatureContext extends Context {
    function handleSuccess(data) {
        data.description <- getPart(data.signature).desc;
        base.handleSuccess(data);
    }
}

// First we get the signature so we can request and submit the part with
// the sending of the real upload context in the handleSuccess(...) logic.
class UploadHexPartContext extends Context {
    uploadHexData = null
    constructor(_response, _data) {
        base.constructor(GET_SIGNATURE_ACTION, _response);
        uploadHexData = _data;
    }
    
    function handleSuccess(_data) {
        uploadHexData.part <- getPart(_data.signature);
        send(Context(UPLOAD_HEX_ACTION, response, uploadHexData));
    }
}

function send(context) {
    // Don't mysteriously timeout in the case where the Imp isn't even plugged in.
    if (!pinger.isDeviceConnected())
        throw "device is not connected";
        
    addContext(context);
    device.send("actionSend", context.data);
}

device.on("actionSuccessReply", function (data) {
    removeContext(data).handleReply(data, true);
});
device.on("actionFailureReply", function (data) {
    removeContext(data).handleReply(data, false);
});

contextCache <- { };

contextCacheKeyNext <- 0;

function addContext(context) {
    context.data.key <- contextCacheKeyNext++;
    
    contextCache[context.data.key] <- context;
}

function removeContext(data) {
    return delete contextCache[delete data.key];
}

// -----------------------------------------------------------------------------

function handleAction(action, request, response) {
    try {
        local context;

        switch (action) {
        case GET_SIGNATURE_ACTION:
            context = SignatureContext(action, response);
            break;
        case "setFuses":
            context = Context(action, response, getSetFusesParams(request));
            break;
        case "setLockBits":
            context = Context(action, response, getSetLockBitsParam(request));
            break;
        case UPLOAD_HEX_ACTION:
            context = UploadHexPartContext(response, getUploadHexParam(request));
            break;
        default:
            context = Context(action, response);
            break;
        }        

        send(context);
    } catch (ex) {
        sendException(response, ex, { action = action });
    }
}

function sendJson(code, response, data) {
    response.header("Content-Type", "application/json");
    response.send(code, http.jsonencode(data));
}

function sendException(response, ex, data = {}) {
    try {
        // You can throw null.
        data.message <- ex != null ? ex.tostring() : "null exception";
    
        sendJson(500, response, data);
    } catch (sendEx) {
        // If we can't send the exception to the client at least log it here.
        server.log(ex);
        server.log(sendEx);
    }
}

function requestHandler(request, response) {
    try {
        if (startsWith(request.path, ACTION_PATH)) {
            local action = request.path.slice(ACTION_PATH.len());

            handleAction(action, request, response);
        } else if (request.path == PROGRAMMER_PATH) {
            response.header("Content-Type", "text/html; charset=utf-8");
            response.send(200, getIndex());
        } else if (request.path == NO_TRAILING_SLASH || request.path == PROGRAMMER_PATH + "index.html") {
            // Redirect to correct URL if trailing slash missing or index.html added.
            response.header("Location", http.agenturl() + PROGRAMMER_PATH);
            response.send(302, "");
        } else if (startsWith(request.path, PROGRAMMER_PATH)) {
            local subpath = request.path.slice(PROGRAMMER_PATH.len());
            
            response.header("Location", SRC_BASE_URL + subpath);
            response.send(302, "");
        }
    } catch (ex) {
        sendException(response, ex);
    }
}

http.onrequest(requestHandler);

// 2014-7-8: device.isconnected() returned true for my device even though it
// had been disconnected overnight. This class is derived from Hugo's code:
// http://forums.electricimp.com/discussion/comment/14500#Comment_14500
pinger <- class {
    static POLL_PERIOD = 10; // Poll every 10s.
    lastResponse = 0;
    
    constructor() {
        // TODO: is there a better way to capture the containing "this".
        local self = this;
        
        device.on("pong", function(data) { self.lastResponse = time(); });
        
        // Try to pick up connect and disconnect events immediately.
        device.onconnect(function() { self.lastResponse = time(); });
        device.ondisconnect(function() { self.lastResponse = 0; });
        
        pollDevice();
    }

    function pollDevice() {
        local self = this;
        imp.wakeup(POLL_PERIOD, function() { self.pollDevice() });
        device.send("ping", 0);
    }

    function isDeviceConnected() {
      // Did we hear from device recently?
      return (time() - lastResponse) < (POLL_PERIOD * 1.5);
    }
}();

// -----------------------------------------------------------------------------
// Start - Intel HEX parser library
// -----------------------------------------------------------------------------
function ignore(line) {
    server.log("Error: ignoring line \"" + line + "\"");
}

function dehex(c) {
    return (c >= 'a' ? (c - 'a' + 10) : (c >= 'A' ? (c - 'A' + 10) : (c - '0')));
}

function getByte(line, offset) {
    return (dehex(line[offset]) << 4) + dehex(line[offset + 1]);
}

function parseIntelHex(content) {
    local program = [];
    local count = 0;
    
    foreach (line in split(content, "\r\n")) {
        if (line.len() < 11) {
            ignore(line);
            continue;
        }
        
        if (line[0] != ':') {
            ignore(line);
            continue;
        }
        
        local len = getByte(line, 1);
        
        if (line.len() != (len * 2) + 11) {
            ignore(line);
            continue;
        }
        
        local addr = getByte(line, 3) << 8;
        addr += getByte(line, 5);
        local type = getByte(line, 7);
        local offset = 9;
        
        local data = blob(len);
        
        for (local i = 0; i < len; i++) {
            data.writen(getByte(line, offset), 'b');
            offset += 2;
        }
        
        // TODO: verify checksum.
        local checksum = getByte(line, offset);
        
        program.append({
            addr = addr
            type = type
            data = data
        });
    }
    
    server.log("Info: read " + program.len() + " lines of hex");
    
    return programToBlob(program);
}

// TODO: build up blob directly - start with a 64KB blob - there's no point in
// Note: a blob needs an initial size but it will automatically grow if this
// size is exceeded (or you can explicitly resize).
// a larger blob given the Imp's memory constraints.
function programToBlob(program) {
    local size = 0;
    
    foreach (line in program) {
        size += 2; // addr
        size += 1; // type
        size += 1; // len
        size += line.data.len();
    }
    
    local result = blob(size);

    foreach (line in program) {
        result.writen(line.addr, 'w');
        result.writen(line.type, 'b');
        result.writen(line.data.len(), 'b');
        result.writeblob(line.data);
    }

    return result;
}
// -----------------------------------------------------------------------------
// End - Intel HEX parser library
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Start - Multipart form data library
// -----------------------------------------------------------------------------
const FORM_DATA = "Content-Disposition: form-data";
const CONTENT_TYPE = "Content-Type:";

function startsWith(a, b) {
    return a.len() >= b.len() && a.slice(0, b.len()) == b;
}

class MultipartItem {
    name = null;
    filename = null;
    type = null;
    content = null;
    
    function _tostring() {
        return "[ " + (name != null ? "name=\"" + name + "\" " : "") +
            (filename != null ? "filename=\"" + filename + "\" " : "") +
            (type != null ? "type=\"" + type + "\" " : "") +
            (content != null ? "content=\"" + content + "\" " : "") + "]";
    }
}

function parseHeader(item, header) {
    if (startsWith(header, FORM_DATA)) {
        local params = header.slice(FORM_DATA.len());
        local middle;
        local offset = 0;
        
        while ((middle = params.find("=\"", offset)) != null) {
            local key = params.slice(offset, middle);
            middle += 2;
            offset = params.find("\"", middle);
            local value = params.slice(middle, offset);
            offset++;
            
            // Remove semicolon and any whitespace.
            key = key.slice(1);
            key = strip(key);
            
            if (key == "name") {
                item.name = value;
            } else if (key == "filename") {
                item.filename = value;
            } else {
                server.log("Error: unknown disposition parameter " + key + "=\"" + value + "\"");
            }
        }
    } else if (startsWith(header, CONTENT_TYPE)) {
        item.type = strip(header.slice(CONTENT_TYPE.len()));
    } else {
        server.log("Error: unknown header <" + header + ">");
    }
}

function isMultipart(request) {
    return ("content-type" in request.headers) &&
        startsWith(request.headers["content-type"], "multipart");
}

function parseMultipart(req) {
    local result = { };

    local boundary = req.headers["content-type"];
    boundary = boundary.slice(boundary.find("=") + 1);

    local body = req.body;
    local offset = body.find(boundary);
    
    if (offset == null) {
        return { };
    }

    offset += boundary.len() + 2;
    
    local end;
    
    while ((end = body.find("\r\n--" + boundary, offset)) != null) {
        local headerEnd = body.find("\r\n\r\n", offset);
        local bodyStart = headerEnd + 4;
        local header = body.slice(offset, headerEnd);
        local item = MultipartItem();
        
        foreach (val in split(header, "\r\n")) {
            parseHeader(item, val);
        }
        item.content = body.slice(bodyStart, end);
        
        if (item.name in result) {
            // The same name is used multiple times, e.g. multiple file upload.
            if (!(typeof result[item.name] == "array")) {
                result[item.name] = [ result[item.name] ];
            }
            result[item.name].append(item);
        } else {
            result[item.name] <- item;
        }

        offset = end + 6 + boundary.len();
    }

    return result;
}
// -----------------------------------------------------------------------------
// End - Multipart form data library
// -----------------------------------------------------------------------------
