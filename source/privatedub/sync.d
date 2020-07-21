module privatedub.sync;

import core.sync.mutex : Mutex;

struct Guard(T) {
private:
  Mutex mutex;
public:
  T reg;
  alias reg this;
  @disable this();
  @disable this(this);
  static Guard acquire(shared T reg, Mutex mutex) {
    mutex.lock();
    auto instance = Guard.init;
    instance.reg = (cast() reg);
    instance.mutex = mutex;
    return instance;
  }

  ~this() {
    mutex.unlock();
  }
}
