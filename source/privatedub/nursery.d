module privatedub.nursery;

import std.concurrency : thisTid, Tid, send, receive;
public import privatedub.stoptoken;

import core.atomic;

alias VoidFunction = void function();
alias VoidDelegate = void delegate() shared;

interface SenderObject(Output) {
  OperationObject connect(ReceiverObject!Output receiver);
}

interface ReceiverObject(Input = void) {
  static if (is(Input == void))
    void setValue();
  else
    void setValue(Input value);
  void setDone() nothrow;
  void setError(Exception) nothrow;
}

struct OperationObject {
  private void delegate() _start;
  void start() {
    _start();
  }
}

// dfmt off
class SenderThenObject(Input, Output) : SenderObject!(Output) {
  SenderObject!Input base;
  static if (is(Input == void))
    alias Cont = Output delegate();
  else
    alias Cont = Output delegate(Input);
  Cont cont;
  this(SenderObject!Input base, Cont cont) {
    this.base = base;
    this.cont = cont;
  }
  OperationObject connect(ReceiverObject!Output receiver) {
    return base.connect(new class(receiver, cont) ReceiverObject!(Input) {
          ReceiverObject!Output receiver;
          Cont cont;
          this(ReceiverObject!Output receiver, Cont cont) {
            this.receiver = receiver;
            this.cont = cont;
          }
      static if (is(Input == void)) {
          void setValue() {
            static if (is(Output == void)) {
              cont();
              receiver.setValue();
            } else {
              receiver.setValue(cont());
            }
          }
      } else {
          void setValue(Input var) {
            static if (is(Output == void)) {
              cont(var);
              receiver.setValue();
            } else {
              receiver.setValue(cont(var));
            }
          }
      }
          void setDone() {
            receiver.setDone();
          }
          void setError(Exception e) {
            receiver.setError(e);
          }
      });
  }
}
// dfmt on

auto then(Input, Output)(SenderObject!Input sender, Output delegate(Input) cont)
if (!is(Input == void)) {
  return new SenderThenObject!(Input, Output)(sender, cont);
}

auto then(Input, Output)(SenderObject!Input sender, Output delegate() cont)
if (is(Input == void)) {
  return new SenderThenObject!(Input, Output)(sender, cont);
}

interface Executor {
  void execute(VoidFunction fn);
  void execute(VoidDelegate fn);
  bool isInContext();
}

void executeInNewThread(VoidFunction fn) {
  import core.thread : Thread, thread_detachThis;

  version (Posix) import core.sys.posix.pthread : pthread_detach, pthread_self;

  new Thread(() {
    fn(); //thread_detachThis(); NOTE: see git.kaleidic.io/SIL/plugins/alpha/web/-/issues/3
    version (Posix)
      pthread_detach(pthread_self);
  }).start();
}

void executeInNewThread(VoidDelegate fn) {
  import core.thread : Thread, thread_detachThis;

  version (Posix) import core.sys.posix.pthread : pthread_detach, pthread_self;

  new Thread(() {
    fn(); //thread_detachThis(); NOTE: see git.kaleidic.io/SIL/plugins/alpha/web/-/issues/3
    version (Posix)
      pthread_detach(pthread_self);
  }).start();
}

class ThreadExecutor : Executor {
  void execute(VoidFunction fn) {
    executeInNewThread(fn);
  }

  void execute(VoidDelegate fn) {
    executeInNewThread(fn);
  }

  bool isInContext() {
    return false;
  }
}

// TODO: would be better if we can avoid std.concurrency, since the work might use it itself (e.g. when this function is called from a thread that also does a receive later, and the work send stuff to it...)
auto executeAndWait(Executor, Work, string file = __FILE__, size_t line = __LINE__, Args...)(
    Executor executor, Work work, Args args) {
  import std.concurrency;

  auto tid = thisTid;
  import std.traits;

  if (executor.isInContext)
    return work(args);
  alias RT = ReturnType!Work;
  static if (is(RT == void)) {
    executor.execute(cast(VoidDelegate)() { work(args); tid.send(true); });
    receive((bool _) {});
  }
  else {
    executor.execute(cast(VoidDelegate)() => tid.send(work(args)));
    return receiveOnly!(RT)();
  }

}

shared static this() {
  import std.concurrency;

  if (scheduler !is null)
    scheduler = null; // vibed sets this, we don't want it
}

class ThreadSender : SenderObject!void {
  private ReceiverObject!void receiver;
  OperationObject connect(ReceiverObject!void receiver) {
    assert(this.receiver is null);
    this.receiver = receiver;
    return OperationObject(() => this.start());
  }

  protected void start() {
    executeInNewThread(() shared{
      try {
        receiver.setValue();
      }
      catch (Exception e) {
        receiver.setError(e);
      }
      catch (Throwable t) {
        import std.stdio;

        writeln(t);
        assert(0);
      }
    });
  }
}

shared struct Closure(Fun, Args...) {
  Fun fun;
  Args args;
  auto apply() shared {
    return fun(args);
  }
}

auto closure(Fun, Args...)(Fun fun, Args args) {
  auto cl = new Closure!(Fun, Args)(fun, args);
  return &cl.apply;
}

struct SignalHandler {
  private __gshared void delegate(int) callback = null;
  private void delegate(int) oldCallback;
  extern (C) static void intr(int i) nothrow @nogc {
    if (callback is null)
      return;
    // TODO: this cast is a bit sketchy
    (cast(void delegate(int) nothrow @nogc) callback)(i);
  }

  version (Posix) {
    import core.sys.posix.signal;

    private sigaction_t[int] previous;
  }
  else version (Windows) {
    alias Fun = extern (C) void function(int) nothrow @nogc @system;
    private Fun[int] previous;
  }
  else
    static assert("Platform not supported");

  void setup(void delegate(int) cb) {
    oldCallback = callback;
    callback = cb;
  }

  void on(int s) {
    version (Posix) {
      import core.sys.posix.signal;

      sigaction_t old;
      sigset_t sigset;
      sigemptyset(&sigset);
      sigaction_t siginfo;
      siginfo.sa_handler = &intr;
      siginfo.sa_mask = sigset;
      siginfo.sa_flags = SA_RESTART;
      sigaction(s, &siginfo, &old);
    }
    else {
      import core.stdc.signal;

      Fun old = signal(s, &intr);
    }
    previous[s] = old;
  }

  void forward(int sig) {
    foreach (s, old; previous) {
      if (s != sig)
        continue;
      version (Posix) {
        if (old.sa_handler)
          old.sa_handler(s);
      }
      else if (old)
        old(s);
    }
  }

  void teardown() nothrow {
    callback = oldCallback;
    try {
      foreach (s, old; previous) {
        version (Posix) {
          sigaction(s, &old, null);
        }
        else {
          import core.stdc.signal;

          signal(s, old);
        }
      }
    }
    catch (Exception e) {
    }
  }
}

class Nursery : StopSource {
  import core.sync.condition : Condition, SyncError;
  import core.sync.mutex : Mutex;
  import core.stdc.signal;

  private Node[] operations;
  private struct Node {
    OperationObject operation;
    size_t id;
  }

  private Mutex mutex;
  private Mutex conditionMutex;
  private Condition condition;
  private size_t busy = 0;
  private shared size_t counter = 0;
  private shared bool ended = false;
  private SignalHandler signalHandler;
  this() {
    import std.concurrency;

    if (scheduler !is null)
      scheduler = null; // vibed sets this, we don't want it
    mutex = new Mutex();
    conditionMutex = new Mutex();
    condition = new Condition(conditionMutex);
    signalHandler.setup(&this.interruptStop);
    signalHandler.on(SIGINT);
    signalHandler.on(SIGTERM);
  }

  ~this() {
    cleanup();
  }

  StopToken getStopToken() {
    return StopToken(this);
  }

  void sync_wait() {
    waitForCompletion();
    cleanup();
  }

  private void waitForCompletion() {
    try {
      if (busy > 0)
        synchronized (conditionMutex)
          (cast() condition).wait();
    }
    catch (SyncError e) {
    }
  }

  override bool stop() {
    if (!super.stop())
      return false;
    return true;
  }

  private void interruptStop(int i) {
    stop();
  }

  private void cleanup() nothrow {
    import core.atomic;

    if (cas(&ended, false, true))
      signalHandler.teardown();
  }

  private void done(size_t id) nothrow {
    import std.algorithm : countUntil, remove;

    mutex.lock_nothrow();
    scope (exit)
      mutex.unlock_nothrow();
    auto idx = operations.countUntil!(o => o.id == id);
    if (idx != -1)
      operations = operations.remove(idx);
    busy--;

    if (busy == 0) {
      try {
        synchronized (conditionMutex)
          (cast() condition).notify();
      }
      catch (Exception e) {
        // TODO: assert???
      }
      cleanup();
    }
  }

  SenderObject!void thread() {
    return new ThreadSender();
  }

  void run(Sender)(Sender sender) {
    import std.typecons : Nullable;
    import core.atomic;

    if (sender is null)
      return;

    static if (is(Sender == Nullable!T, T)) {
      if (!sender.isNull)
        run(sender.get());
    }
    else {
      size_t id = atomicOp!"+="(counter, 1);
      auto op = sender.connect(new NurseryReceiver(this, id));
      mutex.lock();
      // TODO: might also use the receiver as key instead of a wrapping ulong
      operations ~= Node(op, id);
      busy++;
      mutex.unlock();
      op.start();
    }
  }
}

private class NurseryReceiver : ReceiverObject!void {
  Nursery nursery;
  size_t id;
  this(Nursery nursery, size_t id) {
    this.nursery = nursery;
    this.id = id;
  }

  void setValue() shared {
    (cast() this).setDone();
  }

  void setValue() {
    nursery.done(id);
  }

  void setDone() nothrow {
    nursery.done(id);
  }

  void setError(Exception e) nothrow {
    try {
      import std.stdio;

      writeln("Error: ", e);
    }
    catch (Exception e) {
    }
    nursery.done(id);
  }
}
