#include <Arduino.h>
#include <WiFi.h>
#include "chess_protocol.h"
#include "web_page.h"

#if !defined(ARDUINO_RASPBERRY_PI_PICO_W)
#error "Select Raspberry Pi Pico W, as in the oscilloscope example."
#endif

// Use the oscilloscope reference's default AP setup, GPIOs and UART rate.
constexpr char WIFI_NAME[] = "FPGA-Chess";
constexpr char WIFI_PASSWORD[] = "fpgachess";
constexpr uint32_t UART_BAUD=115200;
WiFiServer webServer(80);
WiFiClient client;
ChessLink::Parser parser;
uint32_t sequence=0, lastLink=0, nextWifi=0, lastProgress=0;
bool wifiReady=false, linkSeen=false;

// One bounded HTTP connection at a time. The FPGA evaluates independently;
// commands acknowledge quickly and the browser polls status between requests.
enum HttpState { IDLE, HEADERS, BODY, SENDING };
HttpState httpState=IDLE;
char line[192]={}, method[8]={}, path[80]={}, body[163]={};
size_t lineSize=0, headerBytes=0, bodySize=0, contentLength=0;
bool firstLine=true, lengthSeen=false;
char responseHeader[256]={}, responseBody[2304]={};
const char* sendBody=nullptr;
size_t headerSize=0, headerSent=0, sendSize=0, bodySent=0;

void respond(unsigned code, const char* type, const char* data, size_t length) {
  const char* reason=code==200?"OK":code==400?"Bad Request":code==404?"Not Found":
    code==405?"Method Not Allowed":code==408?"Request Timeout":code==413?"Content Too Large":
    code==431?"Request Header Fields Too Large":"Gateway Timeout";
  headerSize=snprintf(responseHeader,sizeof(responseHeader),
    "HTTP/1.1 %u %s\r\nContent-Type: %s\r\nContent-Length: %u\r\n"
    "Cache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n",
    code,reason,type,unsigned(length));
  headerSent=bodySent=0;sendBody=data;sendSize=length;
  httpState=SENDING;lastProgress=millis();
}
void errorResponse(unsigned code, const char* message) {
  snprintf(responseBody,sizeof(responseBody),"{\"error\":\"%s\"}",message);
  respond(code,"application/json",responseBody,strlen(responseBody));
}
bool transact(const uint8_t* payload,size_t length) {
  uint8_t packet[ChessLink::MAX_REQUEST+10];
  const uint32_t id=++sequence;
  const size_t size=ChessLink::request(packet,id,payload,length);
  for(unsigned attempt=0;attempt<3;attempt++) {
    parser.reset();
    while(Serial1.available()) Serial1.read();
    Serial1.write(packet,size);
    const uint32_t start=millis();uint32_t byteTime=start;
    while(millis()-start<300) {
      while(Serial1.available()) {
        const uint8_t b=uint8_t(Serial1.read());
        if(millis()-byteTime>50) parser.reset();
        byteTime=millis();
        if(parser.feed(b) && parser.sequence()==id) {
          lastLink=millis();linkSeen=true;return true;
        }
      }
      delay(0);
    }
    // Retry the SAME sequence: the engine's mutation token prevents replay.
  }
  return false;
}
void dispatch() {
  if(strcmp(method,"GET")==0 && strcmp(path,"/")==0) {
    respond(200,"text/html; charset=utf-8",WEB_PAGE,sizeof(WEB_PAGE)-1);return;
  }
  if(strcmp(method,"GET")==0 && strcmp(path,"/api/info")==0) {
    snprintf(responseBody,sizeof(responseBody),
      "{\"device\":\"Pico W\",\"uartBaud\":115200,\"fpgaSeen\":%s,\"lastReplyMsAgo\":%lu}",
      linkSeen?"true":"false",static_cast<unsigned long>(millis()-lastLink));
    respond(200,"application/json",responseBody,strlen(responseBody));return;
  }
  if(strcmp(path,"/api/command")!=0) {errorResponse(404,"Unknown path");return;}
  if(strcmp(method,"POST")!=0) {errorResponse(405,"Use POST");return;}
  if(!lengthSeen || contentLength<2 || (contentLength&1) || contentLength>162) {
    errorResponse(400,"Expected 1 to 81 command bytes encoded as hexadecimal");return;
  }
  uint8_t payload[81];
  for(size_t i=0;i<contentLength;i+=2) {
    const int a=ChessLink::unhex(body[i]),b=ChessLink::unhex(body[i+1]);
    if(a<0||b<0) {errorResponse(400,"Invalid hexadecimal body");return;}
    payload[i/2]=uint8_t((a<<4)|b);
  }
  if(!transact(payload,contentLength/2)) {errorResponse(504,"No FPGA reply. Check FPGA image and UART wiring.");return;}
  size_t offset=snprintf(responseBody,sizeof(responseBody),"{\"status\":%u,\"payload\":\"",parser.status());
  constexpr char hex[]="0123456789abcdef";
  for(size_t i=0;i<parser.length();i++) {
    const uint8_t b=parser.data()[i];responseBody[offset++]=hex[b>>4];responseBody[offset++]=hex[b&15];
  }
  responseBody[offset++]='"';responseBody[offset++]='}';responseBody[offset]=0;
  respond(200,"application/json",responseBody,offset);
}
bool parseHeader() {
  line[lineSize]=0;
  if(firstLine) {
    char version[16];
    if(sscanf(line,"%7s %79s %15s",method,path,version)!=3 ||
       (strcmp(version,"HTTP/1.1")&&strcmp(version,"HTTP/1.0"))) {
      errorResponse(400,"Invalid HTTP request");return false;
    }
    firstLine=false;
  } else if(!lineSize) {
    if(!strcmp(method,"POST")) {
      if(!lengthSeen) {errorResponse(400,"Content-Length required");return false;}
      httpState=BODY;
      if(!contentLength) dispatch();
    } else dispatch();
    return false;
  } else if(!strncasecmp(line,"Content-Length:",15)) {
    const char* s=line+15;while(*s==' '||*s=='\t') ++s;
    if(lengthSeen||!*s) {errorResponse(400,"Invalid Content-Length");return false;}
    lengthSeen=true;contentLength=0;
    for(;*s;s++) {
      if(*s<'0'||*s>'9') {errorResponse(400,"Invalid Content-Length");return false;}
      contentLength=contentLength*10+unsigned(*s-'0');
      if(contentLength>162) {errorResponse(413,"Command exceeds 81 bytes");return false;}
    }
  } else if(!strncasecmp(line,"Transfer-Encoding:",18)) {
    errorResponse(400,"Transfer encoding is unsupported");return false;
  }
  lineSize=0;return true;
}
void pollHttp() {
  if(httpState==IDLE) {
    client=webServer.accept();if(!client) return;
    client.setNoDelay(true);
    lineSize=headerBytes=bodySize=contentLength=0;firstLine=true;lengthSeen=false;
    method[0]=path[0]=0;lastProgress=millis();httpState=HEADERS;
  }
  if(!client.connected()) {client.stop();httpState=IDLE;return;}
  if(millis()-lastProgress>3000) {client.stop();httpState=IDLE;return;}
  for(unsigned budget=0;budget<256 && client.available() && (httpState==HEADERS||httpState==BODY);budget++) {
    const char c=char(client.read());lastProgress=millis();
    if(httpState==BODY) {
      body[bodySize++]=c;
      if(bodySize==contentLength) {body[bodySize]=0;dispatch();}
    } else {
      if(++headerBytes>1024) {errorResponse(431,"Headers exceed 1024 bytes");break;}
      if(c=='\n') {if(!parseHeader()) break;}
      else if(c!='\r') {
        if(lineSize>=sizeof(line)-1) {errorResponse(431,"Header line too long");break;}
        line[lineSize++]=c;
      }
    }
  }
  if(httpState==SENDING) {
    const bool header=headerSent<headerSize;
    const char* p=header?responseHeader+headerSent:sendBody+bodySent;
    const size_t left=header?headerSize-headerSent:sendSize-bodySent;
    const size_t available=client.availableForWrite();
    const size_t count=min(size_t(768),min(left,available));
    if(count) {
      const size_t sent=client.write(reinterpret_cast<const uint8_t*>(p),count);
      if(header) headerSent+=sent;else bodySent+=sent;
      if(sent) lastProgress=millis();
    }
    if(headerSent==headerSize && bodySent==sendSize) {client.stop();httpState=IDLE;}
  }
}
void setup() {
  Serial.begin(115200); // Do not wait for a USB serial monitor.
  Serial1.setTX(0);Serial1.setRX(1);Serial1.setFIFOSize(2048);Serial1.begin(UART_BAUD,SERIAL_8N1);
  pinMode(LED_BUILTIN,OUTPUT);sequence=micros();
}
void loop() {
  if(!wifiReady && int32_t(millis()-nextWifi)>=0) {
    nextWifi=millis()+5000;
    WiFi.setTimeout(1000);
    if(WiFi.softAP(WIFI_NAME,WIFI_PASSWORD)) {
      wifiReady=true;webServer.begin();webServer.setNoDelay(true);
      Serial.print("Wi-Fi: ");Serial.println(WIFI_NAME);
      Serial.print("Open http://");Serial.println(WiFi.softAPIP());
      sequence^=micros()<<8;
    }
  }
  if(wifiReady) pollHttp();
  digitalWrite(LED_BUILTIN,linkSeen && millis()-lastLink<3000?HIGH:((millis()/500)&1));
  delay(0);
}
