FROM ubuntu

RUN apt -qq update && apt -qq -y install git

RUN useradd -m private-dub

USER private-dub
WORKDIR /home/private-dub

COPY --chown=private-dub:private-dub private-dub /home/private-dub/

ENTRYPOINT ["./private-dub"]
