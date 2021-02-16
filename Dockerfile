FROM ubuntu

RUN apt -qq update && apt -qq -y install git

RUN useradd -m private-dub

USER private-dub
WORKDIR /home/private-dub

COPY private-dub /home/private-dub/private-dub

ENTRYPOINT ["./private-dub"]
