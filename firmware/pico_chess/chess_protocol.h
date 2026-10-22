#pragma once
#include <stdint.h>
#include <stddef.h>

namespace ChessLink {
constexpr size_t MAX_REQUEST = 81, MAX_REPLY = 1024;
inline uint16_t crcByte(uint16_t crc, uint8_t byte) {
  crc ^= uint16_t(byte) << 8;
  for (unsigned bit=0; bit<8; ++bit)
    crc = (crc & 0x8000) ? uint16_t((crc << 1) ^ 0x1021) : uint16_t(crc << 1);
  return crc;
}
inline size_t request(uint8_t* out, uint32_t sequence, const uint8_t* data, size_t length) {
  if (!length || length > MAX_REQUEST) return 0;
  out[0]='C'; out[1]='F'; out[2]=1;
  for (unsigned i=0; i<4; ++i) out[3+i]=uint8_t(sequence >> (24-8*i));
  out[7]=uint8_t(length);
  uint16_t crc=0xffff;
  for (size_t i=0; i<length; ++i) out[8+i]=data[i];
  for (size_t i=2; i<8+length; ++i) crc=crcByte(crc,out[i]);
  out[8+length]=uint8_t(crc>>8); out[9+length]=uint8_t(crc);
  return length+10;
}
struct Parser {
  uint8_t bytes[MAX_REPLY+12] = {};
  size_t used=0, expected=0;
  void reset() { used=expected=0; }
  bool feed(uint8_t b) {
    if (!used) { if (b=='F') bytes[used++]=b; return false; }
    if (used==1) {
      if (b=='C') bytes[used++]=b;
      else if (b!='F') reset();
      return false;
    }
    if (used==2 && b!=1) {reset(); return false;}
    bytes[used++]=b;
    if (used==10) {
      const size_t length=(size_t(bytes[8])<<8)|bytes[9];
      if (length>MAX_REPLY) {reset();return false;}
      expected=length+12;
    }
    if (!expected || used<expected) return false;
    uint16_t crc=0xffff;
    for (size_t i=2; i<expected-2; ++i) crc=crcByte(crc,bytes[i]);
    const bool ok=bytes[expected-2]==uint8_t(crc>>8) && bytes[expected-1]==uint8_t(crc);
    reset(); return ok;
  }
  uint32_t sequence() const {
    return (uint32_t(bytes[3])<<24)|(uint32_t(bytes[4])<<16)|(uint32_t(bytes[5])<<8)|bytes[6];
  }
  uint8_t status() const {return bytes[7];}
  size_t length() const {return (size_t(bytes[8])<<8)|bytes[9];}
  const uint8_t* data() const {return bytes+10;}
};
inline int unhex(char c) {
  if(c>='0'&&c<='9') return c-'0';
  if(c>='a'&&c<='f') return c-'a'+10;
  if(c>='A'&&c<='F') return c-'A'+10;
  return -1;
}
}
