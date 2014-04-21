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
        server.log( network.bssid + " = " + network.rssi );
    }

    local request = http.get(url);
    local response = request.sendsync();

    if (response.statuscode == 200) {
        local data = http.jsondecode(response.body);
        local timezoneURL = "https://maps.googleapis.com/maps/api/timezone/json?location=" + data.location.lat + "," + data.location.lng+"&timestamp="+time()+"&sensor=false";
        request = http.get( timezoneURL );
        response = request.sendsync();

        if (response.statuscode == 200) {
          data = http.jsondecode( response.body );
          foreach( i,v in data ) {
            server.log(i + ":" + v);
          }
          server.log("Local time is " +getLocalTime( data.rawOffset + data.dstOffset ) );
          device.send("timezoneoffset", data.rawOffset + data.dstOffset );
        }
        else {
            server.log("Response Error " + response.statuscode + " " + response.body );
        }
    }
    else {
      server.log("Response Error " + response.statuscode + " " + response.body );
    }
    
});

function getLocalTime( offset ) {
  local dateTime = date( time() + offset,"u");
  return format("%02d-%02d-%02d %02d:%02d:%02d",dateTime.year,dateTime.month+1,dateTime.day, dateTime.hour, dateTime.min, dateTime.sec );
}
