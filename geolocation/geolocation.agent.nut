function addColons(bssid) {
    local result = bssid.slice(0, 2);
    
    for (local i = 2; i < 12; i += 2) {
        result += ":" + bssid.slice(i, (i + 2));
    }
    
    return result;
}

device.on("location", function (location) {
    local url = "https://maps.googleapis.com/maps/api/browserlocation/json?browser=electric-imp&sensor=false";
    
    foreach (network in location) {
        url += ("&wifi=mac:" + addColons(network.bssid) + "|ss:" + network.rssi);
    }

    local request = http.get(url);
    local response = request.sendsync();

    if (response.statuscode == 200) {
        local data = http.jsondecode(response.body);
        
        server.log("http://maps.google.com/maps?q=loc:" + data.location.lat + "," + data.location.lng);
    }
});
