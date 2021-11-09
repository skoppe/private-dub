module privatedub.server;
import arsd.cgi;
import concurrency.nursery;
import concurrency.thread;
import concurrency.operations;
import concurrency.utils : closure;
import concurrency.stoptoken : onStop, StopToken;

public import arsd.cgi : Cgi;

void runCgi(alias handler)(shared Nursery nursery, ushort port = 8888, string host = "") {
	cgiMainImpl!(handler, Cgi)(nursery, port, host);
}

void cgiMainImpl(alias fun, CustomCgi = Cgi, long maxContentLength = defaultMaxContentLength)(shared Nursery nursery, ushort port = 8888, string host = "") if(is(CustomCgi : Cgi)) {
	import core.sys.windows.windows;
	import core.sys.posix.unistd;
	import core.sys.posix.sys.socket;
	import core.sys.posix.netinet.in_;
	import core.sys.posix.sys.wait;
	import core.stdc.stdio : fprintf, stderr;
	import core.sys.posix.sys.select;
	import core.sys.posix.netinet.tcp;
	import core.stdc.errno;
	import core.stdc.stdlib : exit;
	import std.socket;
	import std.algorithm : max;
  version (linux) import core.sys.linux.sys.eventfd;

  static auto closeSocket(Sock)(Sock sock) {
		version (Windows)
			closesocket(sock);
		else
			close(sock);
	}
	static auto socketListen(ushort port, string host) {
		socket_t sock = cast(socket_t)socket(AF_INET, SOCK_STREAM, 0);
		if(sock == -1)
			throw new Exception("socket");

		sockaddr_in addr;
		addr.sin_family = AF_INET;
		addr.sin_port = htons(port);

		auto lh = host;
		if(lh.length) {
			// version (Windows) {
			import std.string : toStringz;
				uint uiaddr = ntohl(inet_addr(lh.toStringz()));
				if (INADDR_NONE == uiaddr)
					{
						throw new Exception("bad listening host given, please use an IP address.\nExample: --listening-host 127.0.0.1 means listen only on Localhost.\nExample: --listening-host 0.0.0.0 means listen on all interfaces.\nOr you can pass any other single numeric IPv4 address.");

					}
				addr.sin_addr.s_addr = htonl(uiaddr);
			// }
			// if(inet_pton(AF_INET, lh.toStringz(), &addr.sin_addr.s_addr) != 1)
			// 	throw new Exception("bad listening host given, please use an IP address.\nExample: --listening-host 127.0.0.1 means listen only on Localhost.\nExample: --listening-host 0.0.0.0 means listen on all interfaces.\nOr you can pass any other single numeric IPv4 address.");
		} else
			addr.sin_addr.s_addr = INADDR_ANY;

		// HACKISH
		int on = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &on, on.sizeof);
		version (Posix) // on windows REUSEADDR includes REUSEPORT
			setsockopt(sock, SOL_SOCKET, SO_REUSEPORT, &on, on.sizeof);
		// end hack

		if(bind(sock, cast(sockaddr*) &addr, addr.sizeof) == -1) {
			closeSocket(sock);
			throw new Exception("bind");
		}

		// FIXME: if this queue is full, it will just ignore it
		// and wait for the client to retransmit it. This is an
		// obnoxious timeout condition there.
		if(sock.listen(128) == -1) {
			closeSocket(sock);
			throw new Exception("listen");
		}
		return sock;
	}
	socket_t sock = socketListen(port, host);
	scope (exit)
		closeSocket(sock);

	auto stopToken = nursery.getStopToken();

	void runChild(alias fun)(socket_t s, StopToken stopToken) @trusted {
		assert(s);
		bool closeConnection;

		BufferedInputRange ir;
		auto socket = new Socket(cast(socket_t)s, AddressFamily.INET);
		try {
			ir = new BufferedInputRange(socket);
		} catch (Exception e) {
			socket.close();
			throw e;
		}

    while (!ir.empty) {
			Cgi cgi;
			try {
				cgi = new CustomCgi(ir, &closeConnection);
				cgi._outputFileHandle = s;
			}	catch (Exception t) {
				if (cast(SocketOSException)t is null && cast(ConnectionException)t is null)
          ir.source.dumpError(t);
        break;
      } catch (Throwable t) {
				ir.source.close();
				throw t;
			}
			assert(cgi !is null);
			scope (exit)
				cgi.dispose();

			try {
				fun(cgi);
				cgi.close();
			}
			catch (ConnectionException ce) {
				closeConnection = true;
			}
			catch (Throwable t) {
        if (auto exception = cast(Exception)t) {
          ir.source.dumpError(exception);
        }
				ir.source.close();
				throw t;
			}

			if (closeConnection) {
				ir.source.close();
				break;
			} else if (stopToken.isStopRequested) {
				break;
			} else {
        if (!ir.empty)
					ir.popFront(); // get the next
        else if (ir.sourceClosed) {
          ir.source.close();
        }
      }
    }

    ir.source.close();
  }

  version (linux) {
    shared int stopfd = eventfd(0, EFD_CLOEXEC);
    scope (exit)
      close(stopfd);

    auto cb = stopToken.onStop(() shared @trusted {
      ulong b = 1;
      write(stopfd, &b, typeof(b).sizeof);
    });
    scope (exit)
      cb.dispose();
  }

  while(!stopToken.isStopRequested) {
		fd_set read_fds;
		FD_ZERO(&read_fds);
		FD_SET(sock, &read_fds);
    version (linux) {
      FD_SET(stopfd, &read_fds);
    }
    else version (Windows) {
      timeval tv;
      tv.tv_sec = 0;
      tv.tv_usec = 10000;
    }
  retry:
    version (linux) {
      const ret = select(max(sock, stopfd) + 1, &read_fds, null, null, null);
    } else version (Windows) {
      const ret = select(cast(int)(sock + 1), &read_fds, null, null, &tv);
    }
    if (ret == 0)
			continue;
		if (ret == -1) {
			version (Windows) {
				const err = WSAGetLastError();
				if (err == WSAEINTR)
					continue;
			} else {
				if(errno == EINTR || errno == EAGAIN)
          goto retry;
      }
			throw new Exception("wtf select");
		}
    version (linux) {
      if (FD_ISSET(stopfd, &read_fds)) {
        break;
      }
    }
		sockaddr addr;
		version (Windows)
			int i = cast(int)addr.sizeof;
		else
			uint i = addr.sizeof;
		immutable connection = cast(socket_t)accept(sock, &addr, &i);
		if(connection == -1) {
			version (Windows) {
				const err = WSAGetLastError();
				if (err == WSAEINTR)
					break;
			} else {
				if(errno == EINTR)
					break;
			}
			throw new Exception("wtf accept");
		}
		int opt = 1;
		setsockopt(connection, IPPROTO_TCP, TCP_NODELAY, &opt, opt.sizeof);
    struct Temp {
      socket_t connection;
      StopToken stopToken;
      this(socket_t connection, StopToken stopToken) {
        this.connection = connection;
        this.stopToken = stopToken;
      }
      void run() nothrow {
        import privatedub.util;
        runChild!(fun)(cast()connection, cast()stopToken).ignoreException();
      }
    }
		nursery.run(ThreadSender().then(cast(void delegate() shared @safe)&(new Temp(connection, stopToken)).run));
	}
}

import std.socket : Socket;
void dumpError(Socket s, Exception e) {
  import std.format : format;
  auto message = e.msg;
  try {
    sendAll(s, "HTTP/1.1 500 Internal Server Error\r\nContent-Length: %s\r\n\r\n%s".format(message.length, message));
  } catch(Exception e) {}
}
