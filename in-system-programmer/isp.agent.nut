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

const SRC_BASE_URL = "https://george-hawkins.github.io/electric-imp/in-system-programmer/";

const PROGRAMMER_PATH = "/programmer/";
const NO_TRAILING_SLASH = "/programmer";
const ACTION_PATH = "/programmer/action/";
// Note: a const cannot be set to the result of a function call, e.g. slice(...).

const GET_SIGNATURE_ACTION = "getSignature";
const UPLOAD_HEX_ACTION = "uploadHex";

function requestHandler(request, response) {
    try {
        if (startsWith(request.path, ACTION_PATH)) {
            local action = request.path.slice(ACTION_PATH.len());

            handleAction(action, request, response);
        } else if (request.path == PROGRAMMER_PATH) {
            response.header("Content-Type", "text/html; charset=utf-8");
            response.send(200, getContent(SRC_BASE_URL + "index.html"));
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
    local content = http.jsonencode(data);

    try {
        response.header("Content-Type", "application/json");
        response.send(code, content);
    } catch (ex) {
        server.log("exception occurred on sending " + content + " - " + ex);
    }
}

function sendException(response, ex, data = {}) {
        // You can throw null.
        data.message <- ex != null ? ex.tostring() : "null exception";

        sendJson(500, response, data);
}

// -----------------------------------------------------------------------------

// Retrieve this URL for the programmer's web interface.
server.log("Programmer URL: " + http.agenturl() + PROGRAMMER_PATH);

// Retrieve this URL to toggle test mode on or off.
server.log("Test on/off URL: " + http.agenturl() + PROGRAMMER_PATH + "action/test");

// ---------------------------------------------------------------------

function getSetFusesParams(request) {
    return {
        lfuse = getByteParam(request, "lfuse")
        hfuse = getByteParam(request, "hfuse")
        efuse = getByteParam(request, "efuse")
        unsafe = "unsafe" in request.query
    };
}

function getSetLockBitsParam(request) {
    return {
        lockBits = getByteParam(request, "lockBits")
    };
}

const PARAM_HEX_FILE = "hexFile";

function getUploadHexParam(request) {
    local params = multipartParser.getParams(request);

    if (!params.hasParam(PARAM_HEX_FILE)) {
        throw "no HEX file was specified";
    }

    return {
        hexData = intelHexReader.process(params.getParam(PARAM_HEX_FILE).content)
    };
}

// -----------------------------------------------------------------------------

class Context {
    data = null;
    response = null;

    constructor(_action, _response, _data = {}) {
        response = _response;
        data = _data;
        data.action <- _action;
        data.timestamp <- time(); // Note: only to nearest second.
    }

    function handleReply(_data, success) {
        data = _data;

        try {
            // handleSuccess() and handleFailure() are broken out so subclasses
            // can provide alternative implementations.
            (success ? handleSuccess : handleFailure)();
        } catch (ex) {
            sendException(response, ex, data);
        }
    }

    function handleSuccess() {
        sendResponse(200);
    }

    function handleFailure() {
        sendResponse(500);
    }

    function sendResponse(code) {
        sendJson(code, response, data);
    }
}

class SignatureContext extends Context {
    function handleSuccess() {
        data.description <- partSource.get(data.signature).desc;
        base.handleSuccess();
    }
}

// First we get the signature so we can request and submit the part with
// the sending of the real upload context in the handleSuccess(...) logic.
class UploadHexPartContext extends Context {
    uploadHexData = null;

    constructor(_response, _data) {
        base.constructor(GET_SIGNATURE_ACTION, _response);
        uploadHexData = _data;
    }

    function handleSuccess() {
        uploadHexData.part <- partSource.get(data.signature);
        send(Context(UPLOAD_HEX_ACTION, response, uploadHexData));
    }
}

function send(context) {
    contextCache.add(context);
    sender.send("actionSend", context.data, function () {
        context.data.message <- "device is not responding";
        onActionFailureReply(context.data);
    });
}

function onActionFailureReply(data) {
    contextCache.remove(data).handleReply(data, false);
}

function onActionSuccessReply(data) {
    contextCache.remove(data).handleReply(data, true);
}

device.on("actionSuccessReply", onActionSuccessReply);
device.on("actionFailureReply", onActionFailureReply);

contextCache <- class {
    cache = { }
    nextKey = 0;

    function add(context) {
        context.data.key <- nextKey++;

        cache[context.data.key] <- context;
    }

    function remove(data) {
        return delete cache[delete data.key];
    }
}();

// -----------------------------------------------------------------------------

partSource <- class {
    static SIGNATURE_URL = "https://avrdude-conf.herokuapp.com/conf/parts/signatures/";
    static ACCEPT_JSON = { Accept = "application/json" };

    cache = { };

    function get(s) {
        local key = format("0x%02x%02x%02x", s[0], s[1], s[2]);
        local part;

        if (key in cache) {
            part = cache[key];
        } else {
            local start = time();
            local url =  format("%s0x%02x%02x%02x", SIGNATURE_URL, s[0], s[1], s[2]);

            part = http.jsondecode(getContent(url, ACCEPT_JSON));
            cache[key] <- part;

            local diff = time() - start;
            
            if (diff > 0) {
                // Log delay due to Heroku hobbyist tier warmup.
                server.log("querying part took " + diff + "s");
            }
        }

        return part;
    }
}();

// ---------------------------------------------------------------------

hexBytePattern <- regexp("0x[0-9a-fA-F][0-9a-fA-F]");

function getByteParam(request, name) {
    local s = request.query[name];

    if (!hexBytePattern.match(s)) {
        throw name + " should be a hex byte of form \"0xXY\" but was \"" + s + "\"";
    }

    return hexParser.getByte(s, 2);
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
// Start - Sender library
// -----------------------------------------------------------------------------

// device.isconnected() can take a long time to realize the device is no longer
// connected. This singleton provides device.send(...) like behavior but takes an
// additional failure callback argument. The real send only happens if the device
// responds quickly to an initial ping otherwise the failure callback is invoked.
sender <- class {
    static TIMEOUT = 2; // 2s.
    cache = { };
    nextKey = -1;

    constructor() {
        local self = this;

        device.on("pong", function(key) { self.doSuccess(key); });
    }

    function send(_name, _value, _failure) {
        local self = this;
        local key = nextKey++;

        cache[key] <- {
            name = _name
            value = _value
            failure = _failure
        }
        imp.wakeup(TIMEOUT, function() { self.doFailure(key); });
        device.send("ping", key);
    }

    function doSuccess(key) {
        if (key in cache) {
            local data = delete cache[key];

            device.send(data.name, data.value);
        } else {
            // The device responded eventually but not within the timout period.
            server.log("device responded too late");
        }
    }

    function doFailure(key) {
        if (key in cache) {
            local data = delete cache[key];

            server.log("device failed to respond within the timeout period");
            data.failure();
        }
    }
}();
// -----------------------------------------------------------------------------
// End - Sender library
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Start - Intel HEX library
// -----------------------------------------------------------------------------

// Hexadecimal format number parser.
hexParser <- class {
    function getByte(line, offset) {
        return (dehex(line[offset]) << 4) + dehex(line[offset + 1]);
    }

    function dehex(c) {
        return (c >= 'a' ? (c - 'a' + 10) : (c >= 'A' ? (c - 'A' + 10) : (c - '0')));
    }
}();

// Reader for Intel HEX (note the capitals) format - http://en.wikipedia.org/wiki/Intel_HEX
intelHexReader <- class {
    function ignore(line) {
        server.log("Error: ignoring line \"" + line + "\"");
    }

    function process(content) {
        local data = blob(0);
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

            local len = hexParser.getByte(line, 1);

            if (line.len() != (len * 2) + 11) {
                ignore(line);
                continue;
            }

            local addr = hexParser.getByte(line, 3) << 8;
            addr += hexParser.getByte(line, 5);
            local type = hexParser.getByte(line, 7);
            local offset = 9;

            local lineData = blob(len);

            for (local i = 0; i < len; i++) {
                lineData.writen(hexParser.getByte(line, offset), 'b');
                offset += 2;
            }

            // TODO: verify checksum.
            local checksum = hexParser.getByte(line, offset);

            addLine(data, addr, type, lineData);

            count++;
        }

        server.log("read " + count + " lines of hex");

        return data;
    }

    // Continually growing the data blob is probably fairly inefficient but is
    // only marginally slower than more complicated solutions.
    function addLine(data, addr, type, lineData) {
        data.writen(addr, 'w');
        data.writen(type, 'b');
        data.writen(lineData.len(), 'b');
        data.writeblob(lineData);
    }
}
// -----------------------------------------------------------------------------
// End - Intel HEX library
// -----------------------------------------------------------------------------

// -----------------------------------------------------------------------------
// Start - Multipart form data library
// -----------------------------------------------------------------------------
function startsWith(string, suffix) {
    return string.len() >= suffix.len() && string.slice(0, suffix.len()) == suffix;
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

// If a param can take variable number of values, e.g. user can select multiple
// files, then use getListParam to ensure you retrieve a list even if e.g. the
// user only selected one file.
class MultipartParams {
    items = null;

    constructor(_items) {
        items = _items;
    }

    function hasParam(name) {
        return name in items;
    }

    function getParam(name) {
        local item = items[name];

        return (typeof item != "array") ? item : item[0];
    }

    function getListParam(name) {
        local item = items[name];

        return (typeof item == "array") ? item : [ item ];
    }
}

// TODO: class has too many unnamed numeric literals.
multipartParser <- class {
    static FORM_DATA = "Content-Disposition: form-data";
    static CONTENT_TYPE = "Content-Type:";

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

    function getParams(request) {
        local result = { };

        local boundary = request.headers["content-type"];
        boundary = boundary.slice(boundary.find("=") + 1);

        local body = request.body;
        local offset = body.find(boundary);

        if (offset == null) {
            return MultipartParams({ });
        }

        offset += boundary.len() + 2;

        local end;

        while ((end = body.find("\r\n--" + boundary, offset)) != null) {
            local headerEnd = body.find("\r\n\r\n", offset);
            local bodyStart = headerEnd + 4;
            local headers = body.slice(offset, headerEnd);
            local item = MultipartItem();

            foreach (header in split(headers, "\r\n")) {
                parseHeader(item, header);
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

        return MultipartParams(result);
    }
}();
// -----------------------------------------------------------------------------
// End - Multipart form data library
// -----------------------------------------------------------------------------
server.log("agent ready");
