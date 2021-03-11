module privatedub.util;

import std.typecons : Nullable;

struct Unit {}

template andThen(alias fun) {
  auto andThen(T)(Nullable!T t) {
    alias RT = typeof(fun(T.init));
    static if (is(RT == void)) {
      if (!t.isNull) {
        fun(t.get);
        return Nullable!Unit(Unit());
      }
      return Nullable!Unit.init;
    } else static if (is(RT == Nullable!P, P)){
      alias Result = RT;
      if (t.isNull)
        return Result.init;
      return fun(t.get);
    } else {
      alias Result = Nullable!(RT);
      if (t.isNull)
        return Result.init;
      return Result(fun(t.get));
    }
  }
}

unittest {
  import unit_threaded;
  import std.typecons : Nullable;
  import privatedub.util : andThen;

  Nullable!int i;
  i.andThen!(i => i * 2).shouldEqual(Nullable!int.init);
  Nullable!int(4).andThen!(i => i * 2).shouldEqual(Nullable!int(8));
}

template orElse(alias fun) {
  auto orElse(T)(Nullable!T base) {
    if (base.isNull) {
      alias RT = typeof(fun());
      static if (is(RT == void)) {
        fun();
        return Unit();
      } else
        return fun();
    }
    return base.get();
  }
}

auto orElse(T : Nullable!P, P, L)(T base, lazy L orElse) {
  if (base.isNull)
    return orElse;
  return base;
}

unittest {
  import unit_threaded;
  import privatedub.util : orElse;

  Nullable!int a = 5, b = 4;
  a.orElse(b).get.shouldEqual(5);
  Nullable!int.init.orElse(b).get.shouldEqual(4);
}

template filter(alias fun) {
  auto filter(T)(Nullable!T base) {
    if (base.isNull || fun(base.get))
      return base;
    return Nullable!T.init;
  }
}

auto firstOpt(Range)(Range r) {
  import std.range : ElementType, empty, front;
  alias T = ElementType!Range;
  if (r.empty)
    return Nullable!T.init;
  return Nullable!T(r.front);
}
