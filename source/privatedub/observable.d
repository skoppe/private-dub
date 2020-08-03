module privatedub.observable;

struct Subscription(T) {
  Subject!T subject;
  Subject!(T).OnNextDg dg;
  void dispose() {
    if (subject && dg)
      subject.unsubscribe(dg);
  }
}

class Subject(T) {
  static if (is(T == void))
    alias OnNextDg = void delegate();
  else
    alias OnNextDg = void delegate(T);
  private OnNextDg[] subscriptions;
  this() {
  }
  Subscription!T subscribe(OnNextDg dg) {
    subscriptions ~= dg;
    return Subscription!T(this, dg);
  }
  void unsubscribe(OnNextDg dg) {
    import std.algorithm : remove;
    subscriptions = subscriptions.remove!(s => s is dg);
  }
  static if (is(T == void))
    void next() {
      foreach (dg; subscriptions)
        dg();
    }
  else
    void next(T var) {
      foreach (dg; subscriptions)
        dg(var);
    }
}

unittest {
  import unit_threaded;

  auto a = new Subject!ulong();
  ulong[] result;
  a.next(ulong(1));
  a.subscribe((ulong var) { result ~= var; });
  a.next(ulong(2));
  a.next(ulong(3));
  result.shouldEqual([2,3]);
}

// Dead simple stupid timer.
// should probably use a timerwheels implementation instead.
// or at least one that takes into account the time spend
// calling subject.next...
struct SimpleTimer {
  static import core.time;
  import core.time : Duration;
  import privatedub.nursery : Nursery, then;
  import privatedub.stoptoken;

  Nursery nursery;
  Subject!StopToken minutes(ulong t) {
    return duration(core.time.minutes(t));
  }

  Subject!StopToken seconds(ulong t) {
    return duration(core.time.seconds(t));
  }

  Subject!StopToken msecs(ulong t) {
    return duration(core.time.msecs(t));
  }

  Subject!StopToken duration(Duration dur) {
    Subject!StopToken subject = new Subject!StopToken();
    auto stopToken = nursery.getStopToken();
    nursery.run(nursery.thread().then(() {
        import core.sync.mutex : Mutex;
        import core.sync.condition : Condition;

        auto m = new Mutex();
        auto cond = new Condition(m);
        // NOTE: casting to shared is dangerous but this can only be called during the lifetime of this function because we dispose of it here
        auto cb = stopToken.onStop(cast(void delegate() shared nothrow @safe)() nothrow @trusted {
          m.lock_nothrow();
          scope (exit)
            m.unlock_nothrow();
          try {
            cond.notify();
          } catch (Exception e) {
            assert(false, e.msg);
          }
        });
        scope(exit) cb.dispose();
        m.lock_nothrow();
        while (!stopToken.isStopRequested() && !cond.wait(dur)) {
          m.unlock_nothrow();
          subject.next(stopToken);
          m.lock_nothrow();
        }
        m.unlock_nothrow();
      }));
    return subject;
  }
}
