module it.gitlab.crawler;

import privatedub.gitlab.config;
import privatedub.gitlab.crawler;
import privatedub.gitlab.registry;
import requests;
import unit_threaded;
import sumtype;

// These tests require no gitlab setup or anything
// we are just mocking the gitlab server and testing code
// on a very high level. Could be considered component tests.
// run it with: dub -c it -b unittest

alias WorkST = SumType!(CrawlerWorkQueue.WorkItems);

class MockResponse : Response {
  this(string[string] responseHeaders, ushort code, Buffer!ubyte responseBody) {
    __traits(getMember, this, "_responseHeaders") = responseHeaders;
    __traits(getMember, this, "_code") = code;
    __traits(getMember, this, "_responseBody") = responseBody;
  }
  static MockResponse json(string content, ushort code, string[string] responseHeaders = null) {
    auto headers = responseHeaders.dup();
    headers["content-type"] = "application/json";
    auto buffer = Buffer!ubyte();
    buffer.put(content);
    return new MockResponse(headers, code, buffer);
  }
}

@("CrawlEvents")
unittest {
  class MockInterceptor : Interceptor {
    Response opCall(Request rq, RequestHandler next)
    {
      return MockResponse.json(`[{"action_name":"pushed new","author":{"avatar_url":"https:\/\/git.example.com\/uploads\/-\/system\/user\/avatar\/42\/avatar.png","id":42,"name":"John Doe","state":"active","username":"jdoe","web_url":"https:\/\/git.examples.com\/jdoe"},"author_id":42,"author_username":"jdoe","created_at":"2021-10-10T10:39:42.931Z","id":23403,"project_id":892,"push_data":{"action":"created","commit_count":1,"commit_from":null,"commit_title":"Some commit","commit_to":"3ee2d8ef4875b4b3c4798dbc3b6fea1447a5f51c","ref":"v2.9.9","ref_count":null,"ref_type":"tag"},"target_id":null,"target_iid":null,"target_title":null,"target_type":null}]`, 200);
    }
  }

  auto gitlabConfig = GitlabConfig("abcd","git.example.com","./tmp/storage",1,"test.", new MockInterceptor());
  CrawlerWorkQueue queue;
  auto registry = cast(shared) new GitlabRegistry(gitlabConfig);

  CrawlEvents().run(queue, gitlabConfig, registry);
  auto items = queue.flatten();

  items.should == [WorkST(ProjectUpdate(892, [NewTagEvent(892, "v2.9.9", "3ee2d8ef4875b4b3c4798dbc3b6fea1447a5f51c")]))];
}

@("ProjectUpdate")
unittest {
  class MockInterceptor : Interceptor {
    Response opCall(Request rq, RequestHandler next)
    {
      return MockResponse.json(`{"path_with_namespace": "group/project"}`, 200);
    }
  }

  auto gitlabConfig = GitlabConfig("abcd","git.example.com","./tmp/storage",1,"test.", new MockInterceptor());
  CrawlerWorkQueue queue;
  auto registry = cast(shared) new GitlabRegistry(gitlabConfig);

  ProjectUpdate(892, [NewTagEvent(892, "v2.9.9", "3ee2d8ef4875b4b3c4798dbc3b6fea1447a5f51c")]).run(queue, gitlabConfig, registry);

  auto items = queue.flatten();
  items.should == [WorkST(FetchVersionedPackageFile(892, "group/project", "v2.9.9", "3ee2d8ef4875b4b3c4798dbc3b6fea1447a5f51c")),
                   WorkST(MarkProjectCrawled(892, ""))];
}

auto flatten(Queue)(Queue queue) {
  import std.array : Appender;
  import std.algorithm : each;
  alias Ts = SumType!(Queue.WorkItems);
  auto app = Appender!(Ts[])();
  void impl(Queue queue) {
    while(true) {
      auto item = queue.dequeue();
      if (item.isNull)
        return;
      item.get.match!((Queue.SerialWork s) => cast(void)s.queues.each!((ref s) => impl(s)),
                      (Queue.ParallelWork p) => cast(void)p.queue.each!((ref s) => impl(s)),
                      (ref t) => cast(void)app.put(Ts(t)));
    }
  }
  impl(queue);
  return app.data;
}
