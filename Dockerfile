FROM ubuntu

RUN apt -qq update && apt -qq -y install git curl unzip

RUN useradd -m private-dub

RUN curl -L --output private-dub-linux.zip https://github.com/skoppe/private-dub/releases/download/v0.11.0/private-dub-linux.zip && unzip private-dub-linux.zip && mv private-dub /home/private-dub/private-dub

USER private-dub
WORKDIR /home/private-dub

ENTRYPOINT ["./private-dub"]
