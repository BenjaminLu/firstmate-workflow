"""The Linux namespace proxy forwarder for fm-sandbox.sh."""
import os, select, socket, sys, threading


def main():
    sock_path, cmd = sys.argv[1], sys.argv[2:]
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.bind(('127.0.0.1', 0))
    server.listen(64)
    url = 'http://127.0.0.1:%d' % server.getsockname()[1]
    for name in ('HTTP_PROXY', 'HTTPS_PROXY', 'ALL_PROXY', 'http_proxy', 'https_proxy', 'all_proxy'):
        os.environ[name] = url
    parent = os.getpid()
    if os.fork() == 0:
        null = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(null, fd)
        for fd in range(3, 1024):
            if fd != server.fileno():
                try:
                    os.close(fd)
                except OSError:
                    pass

        def relay(client):
            try:
                upstream = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                upstream.connect(sock_path)
                while True:
                    ready, _, _ = select.select([client, upstream], [], [], 600)
                    if not ready:
                        return
                    for s in ready:
                        data = s.recv(65536)
                        if not data:
                            return
                        (upstream if s is client else client).sendall(data)
            except OSError:
                pass
            finally:
                client.close()

        server.settimeout(1)
        while os.getppid() == parent:
            try:
                client, _ = server.accept()
            except socket.timeout:
                continue
            client.settimeout(None)
            threading.Thread(target=relay, args=(client,), daemon=True).start()
        os._exit(0)
    server.close()
    os.execvp(cmd[0], cmd)


if __name__ == "__main__":
    main()
