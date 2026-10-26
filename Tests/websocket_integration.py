"""Native macOS loopback tests of the actual Objective-C++ WebSocket server, no third-party dependencies."""
import base64
import hashlib
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest

TOKEN="1234567890abcdef1234567890abcdef"
KEY=base64.b64encode(b"0123456789abcdef").decode()
class Peer:
    def __init__(self,port,token=TOKEN,split=False):
        self.socket=socket.create_connection(("127.0.0.1",port),timeout=2)
        self.buffer=b""
        request=(f"GET /detections?token={token} HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {KEY}\r\n\r\n").encode()
        if split:
            for chunk in [request[:17],request[17:100],request[100:]]:self.socket.sendall(chunk);time.sleep(.01)
        else:self.socket.sendall(request)
        while b"\r\n\r\n" not in self.buffer:
            data=self.socket.recv(4096)
            if not data:raise ConnectionError("Handshake rejected")
            self.buffer+=data
        header,self.buffer=self.buffer.split(b"\r\n\r\n",1)
        assert b"101 Switching Protocols" in header
        expected=base64.b64encode(hashlib.sha1((KEY+"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest())
        assert expected in header
    def read(self,n):
        while len(self.buffer)<n:
            chunk=self.socket.recv(65536)
            if not chunk:raise ConnectionError("Closed")
            self.buffer+=chunk
        data,self.buffer=self.buffer[:n],self.buffer[n:];return data
    def frame(self):
        a,b=self.read(2);size=b&127
        if size==126:size=struct.unpack("!H",self.read(2))[0]
        elif size==127:size=struct.unpack("!Q",self.read(8))[0]
        assert not b&128
        return a&15,self.read(size)
    def send(self,op,data=b""):
        mask=b"abcd";assert len(data)<126
        self.socket.sendall(bytes([128|op,128|len(data)])+mask+bytes(b^mask[i%4] for i,b in enumerate(data)))
    def until(self,op):
        for _ in range(100):
            code,payload=self.frame()
            if code==9:self.send(10,payload)
            if code==op:return payload
        raise AssertionError("Expected frame was not received")
    def close(self):self.socket.close()

class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        with socket.socket() as probe:probe.bind(("127.0.0.1",0));cls.port=probe.getsockname()[1]
        cls.log=tempfile.TemporaryFile(mode="w+b")
        cls.process=subprocess.Popen([sys.argv[1],str(cls.port),TOKEN],stdout=cls.log,stderr=cls.log)
        for _ in range(100):
            try:
                with socket.create_connection(("127.0.0.1",cls.port),timeout=.1):break
            except OSError:time.sleep(.05)
        else:raise RuntimeError("Server did not start")
    @classmethod
    def tearDownClass(cls):
        cls.process.terminate();cls.process.wait(timeout=5);cls.log.close()
    def counts(self):
        # pread does not change the file offset shared with the child process.
        return os.pread(self.log.fileno(),1_000_000,0).decode()
    def test_1_push_and_multiple_clients(self):
        a=Peer(self.port,split=True);b=Peer(self.port)
        try:
            self.assertEqual(json.loads(a.until(1))["type"],"detections")
            self.assertEqual(json.loads(b.until(1))["detections"],[])
            time.sleep(.1);self.assertIn("clients 2",self.counts())
            a.close();time.sleep(.1)
            self.assertEqual(json.loads(b.until(1))["type"],"detections")
        finally:a.close();b.close()
        time.sleep(.1);self.assertTrue(self.counts().rstrip().endswith("clients 0"))
    def test_2_bad_token(self):
        with self.assertRaises((ConnectionError,ConnectionResetError)):Peer(self.port,"bad")
    def test_3_ping_and_close(self):
        a=Peer(self.port)
        try:
            a.send(9,b"hello");self.assertEqual(a.until(10),b"hello")
            a.send(8,struct.pack("!H",1000));self.assertEqual(struct.unpack("!H",a.until(8))[0],1000)
        finally:a.close()
    def test_4_unmasked_frame_rejected(self):
        a=Peer(self.port)
        try:
            a.socket.sendall(b"\x81\x00");self.assertEqual(struct.unpack("!H",a.until(8))[0],1002)
        finally:a.close()
    def test_5_same_port_restart(self):
        os.kill(self.process.pid,signal.SIGUSR1);time.sleep(.3)
        a=Peer(self.port)
        try:self.assertEqual(json.loads(a.until(1))["type"],"detections")
        finally:a.close()

if __name__=="__main__":unittest.main(argv=[sys.argv[0]],verbosity=2)
