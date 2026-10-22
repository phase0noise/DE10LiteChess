#include "../firmware/pico_chess/chess_protocol.h"
#include <cassert>
#include <cstring>
#include <iostream>
#include <vector>
using namespace ChessLink;
std::vector<uint8_t> reply(uint32_t sequence,size_t n) {
  std::vector<uint8_t> a(n+12);
  a[0]='F';a[1]='C';a[2]=1;
  for(unsigned i=0;i<4;i++) a[3+i]=uint8_t(sequence>>(24-8*i));
  a[7]=3;a[8]=uint8_t(n>>8);a[9]=uint8_t(n);
  for(size_t i=0;i<n;i++) a[10+i]=uint8_t(i);
  uint16_t crc=0xffff;
  for(size_t i=2;i<n+10;i++) crc=crcByte(crc,a[i]);
  a[n+10]=uint8_t(crc>>8);a[n+11]=uint8_t(crc);return a;
}
int main() {
  uint16_t crc=0xffff;for(char c:std::string("123456789"))crc=crcByte(crc,uint8_t(c));assert(crc==0x29b1);
  uint8_t packet[91],payload[81];for(unsigned i=0;i<81;i++)payload[i]=uint8_t(i);
  assert(request(packet,0x12345678,payload,81)==91);
  assert(packet[3]==0x12&&packet[6]==0x78&&packet[7]==81);
  assert(!request(packet,1,payload,0));assert(!request(packet,1,payload,82));
  Parser p;
  for(size_t length: {size_t(0),size_t(32),size_t(80),size_t(1024)}) {
    const auto frame=reply(0x12345678,length);unsigned complete=0;
    for(uint8_t b:frame)if(p.feed(b))complete++;
    assert(complete==1&&p.sequence()==0x12345678&&p.length()==length&&p.status()==3);
    for(size_t i=0;i<length;i++)assert(p.data()[i]==uint8_t(i));
  }
  auto corrupt=reply(4,32);corrupt[15]^=1;for(uint8_t b:corrupt)assert(!p.feed(b));
  for(uint8_t b:{uint8_t(0),uint8_t('F'),uint8_t('F'),uint8_t('C'),uint8_t(2)})assert(!p.feed(b));
  auto tooBig=reply(5,0);tooBig[8]=0xff;tooBig[9]=0xff;for(uint8_t b:tooBig)assert(!p.feed(b));
  auto good=reply(6,80);bool complete=false;for(uint8_t b:good)complete|=p.feed(b);assert(complete);
  for(int i=0;i<10000;i++) p.feed(uint8_t(i*37));
  p.reset();
  complete=false;for(uint8_t b:good)complete|=p.feed(b);assert(complete);
  std::cout<<"UART C++ CRC, frame limits, byte parser, corruption and resynchronization passed.\n";
}
