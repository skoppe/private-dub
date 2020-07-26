module privatedub.util;

import std.typecons : Nullable;

template andThen(alias fun) {
  auto andThen(T)(Nullable!T t) {
    alias RT = Nullable!(typeof(fun(T.init)));
    if (t.isNull)
      return RT.init;
    return RT(fun(t.get));
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
