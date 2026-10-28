import sys
import socket
import threading
import time
import unittest
from pathlib import Path

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'rpi'))
from spi_chess import SpiCommunicationError
from web_app import create_app
from rpi_http_client import HTTPClient

class Link:
    def __init__(self):self.calls=[];self.closed=False;self.status=0
    def close(self):self.closed=True
    def command(self,payload):
        self.calls.append(payload)
        status=bytearray(40);status[:4]=b'SCF2';status[15]=5
        status[36:40]=(50_000_000).to_bytes(4,'big')
        return self.status,bytes(status) if payload==b'\x00' else b'\x00'

class WebTests(unittest.TestCase):
    def setUp(self):
        self.link=Link();self.app=create_app(lambda:self.link);self.client=HTTPClient(self.app)
    def tearDown(self):self.client.close()
    def test_page_and_all_offline_assets(self):
        for name in ['','chess.js','fpga.js','app.js','style.css','pieces.png']:
            with self.client.get('/'+name) as response:
                self.assertEqual(response.status_code,200,name)
                self.assertEqual(response.headers['Cache-Control'],'no-store')
        self.assertEqual(self.link.calls,[])
    def test_command_json_contract(self):
        response=self.client.post('/api/command',data='00',content_type='text/plain')
        self.assertEqual(response.status_code,200);self.assertEqual(response.json['status'],0)
        self.assertTrue(response.json['payload'].startswith('53434632'));self.assertEqual(self.link.calls,[b'\0'])
    def test_invalid_and_oversize_bodies(self):
        for body in ['', '0', 'zz', '00  ', b'\xff\xff']:
            self.assertEqual(self.client.post('/api/command',data=body).status_code,400)
        self.assertEqual(self.client.post('/api/command',data='00'*82).status_code,413)
        self.assertEqual(self.link.calls,[])
    def test_maximum_length_command(self):
        self.assertEqual(self.client.post('/api/command',data='08'+'ff'*80).status_code,200)
        self.assertEqual(len(self.link.calls[0]),81)
    def test_engine_busy_status_preserved(self):
        self.link.status=3;response=self.client.post('/api/command',data='0b')
        self.assertEqual(response.status_code,200);self.assertEqual(response.json['status'],3)
    def test_missing_hardware_and_reconnect(self):
        attempts=[]
        def factory():
            attempts.append(1)
            if len(attempts)==1:raise SpiCommunicationError('No FPGA reply')
            return self.link
        client=HTTPClient(create_app(factory));self.addCleanup(client.close)
        response=client.post('/api/command',data='00');self.assertEqual(response.status_code,503)
        self.assertIn('No FPGA',response.json['error'])
        self.assertEqual(client.post('/api/command',data='00').status_code,200)
    def test_failed_link_is_closed(self):
        class Broken(Link):
            def command(self,payload):raise SpiCommunicationError('SPI failure')
        link=Broken();app=create_app(lambda:link);client=HTTPClient(app);self.addCleanup(client.close)
        self.assertEqual(client.post('/api/command',data='00').status_code,503)
        self.assertTrue(link.closed);self.assertIsNone(app.hardware.link)
    def test_health_checks_real_engine_signature(self):
        self.assertEqual(self.client.get('/healthz').status_code,200)
        self.assertEqual(self.link.calls,[b'\0'])
        self.link.status=3;self.assertEqual(self.client.get('/healthz').status_code,503)
    def test_paths_and_method(self):
        self.assertEqual(self.client.get('/rpi/spi_chess.py').status_code,404)
        self.assertEqual(self.client.get('/api/command').status_code,405)
    def test_head_and_query_string_use_the_same_local_asset(self):
        get=self.client.get('/style.css?version=2')
        head=self.client.request('HEAD','/style.css')
        self.assertEqual(get.status_code,200);self.assertEqual(head.status_code,200)
        self.assertEqual(head.data,b'')
        self.assertEqual(int(head.headers['Content-Length']),len(get.data))
    def test_bad_framing_is_rejected_before_touching_spi(self):
        for header,body,expected in [('Content-Length: -1',b'',400),
                                     ('Content-Length: 99999999999',b'',413),
                                     ('Content-Length: 4',b'00',400),
                                     ('Content-Length: 2\r\nTransfer-Encoding: chunked',b'00',400)]:
            with self.subTest(header=header):
                with socket.create_connection(('127.0.0.1',self.client.server.server_port),timeout=2) as connection:
                    connection.sendall(('POST /api/command HTTP/1.0\r\n'+header+'\r\n\r\n').encode()+body)
                    connection.shutdown(socket.SHUT_WR)
                    response=connection.makefile('rb')
                    self.assertIn((' '+str(expected)+' ').encode(),response.readline())
                    response.close()
        self.assertEqual(self.link.calls,[])
    def test_real_http_threads_serialize_complete_hardware_commands(self):
        class Slow(Link):
            active=0;peak=0
            def command(self,payload):
                self.active+=1;self.peak=max(self.peak,self.active)
                time.sleep(.01)
                try:return super().command(payload)
                finally:self.active-=1
        link=Slow();client=HTTPClient(create_app(lambda:link));self.addCleanup(client.close)
        statuses=[]
        workers=[threading.Thread(target=lambda:statuses.append(client.post('/api/command',data='00').status_code)) for _ in range(6)]
        for worker in workers:worker.start()
        for worker in workers:worker.join(timeout=3)
        self.assertEqual(statuses,[200]*6);self.assertEqual(link.peak,1)

if __name__=='__main__':unittest.main()
