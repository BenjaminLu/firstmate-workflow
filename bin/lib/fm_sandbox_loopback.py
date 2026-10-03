"""The Darwin loopback probe for fm-sandbox.sh."""
import socket, sys


def main():
    print('checked', flush=True)
    for arg in sys.argv[2:]:
        bind = arg.startswith('bind:')
        port = int(arg[len('bind:'):] if bind else arg)
        for family, address in ((socket.AF_INET, '127.0.0.1'), (socket.AF_INET6, '::1')):
            try:
                s = socket.socket(family, socket.SOCK_STREAM)
            except OSError:
                continue
            s.settimeout(2)
            try:
                if bind:
                    s.bind((address, port))
                else:
                    s.connect((address, port))
            except OSError:
                continue
            finally:
                s.close()
            print(arg, flush=True)
            break


if __name__ == "__main__":
    main()
