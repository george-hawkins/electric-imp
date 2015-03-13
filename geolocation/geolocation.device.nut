timezoneOffset <- 0;

agent.send("location", imp.scanwifinetworks());

agent.on("timezoneoffset", function(offset) {
  timezoneOffset = offset;
  server.log("Imp time is : " + getTimeStamp() );
});

function getTimeStamp( ) {
  local dateTime = date( localTime() );
  local timeStamp = format("%02d-%02d-%02d %02d:%02d:%02d",
    dateTime.year,dateTime.month+1,dateTime.day, dateTime.hour, dateTime.min, dateTime.sec );
  return timeStamp;
}

function localTime(){
  return time() + timezoneOffset;
}
