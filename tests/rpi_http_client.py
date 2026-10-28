"""Real loopback HTTP client for the standard-library Pi server."""
import http.client
import json
from threading import Thread

from web_app import make_http_server


class Response:
    def __init__(self, response):
        self.status_code = response.status
        self.headers = dict(response.getheaders())
        self.data = response.read()

    @property
    def json(self):
        return json.loads(self.data)

    def __enter__(self):
        return self

    def __exit__(self, *args):
        pass


class HTTPClient:
    def __init__(self, app):
        self.app = app
        self.server = make_http_server("127.0.0.1", 0, app)
        self.thread = Thread(target=self.server.serve_forever,
                             kwargs={"poll_interval": .01}, daemon=True)
        self.thread.start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.app.close()

    def request(self, method, path, data=None, content_type=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        headers = {"Content-Type": content_type} if content_type else {}
        try:
            connection.request(method, path, body=data, headers=headers)
            return Response(connection.getresponse())
        finally:
            connection.close()

    def get(self, path):
        return self.request("GET", path)

    def post(self, path, data=None, content_type=None):
        return self.request("POST", path, data, content_type)
