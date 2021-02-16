import unit_threaded;

int main(string[] args)
{
  return args.runTests!(
                        "it.gitlab.crawler",
                        "it.gitlab.zip"
                        );
}
