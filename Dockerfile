# build image

FROM alpine as base

RUN apk add --update alpine-sdk ldc dub openssl-dev zlib-dev jq

COPY dub.sdl /app/dub.sdl
COPY dub.selections.json /app/dub.selections.json
RUN cat /app/dub.selections.json | jq -r ' .versions | to_entries | .[] | "\(.key)@\(.value)"' | xargs -t -I% dub fetch %

ADD source /app/source

RUN cd /app && dub build --build=release -c=musl

WORKDIR dist
RUN { ldd /app/private-dub; } | tr -s '[:blank:]' '\n' | grep '^/' | \
  xargs -I% sh -c 'mkdir -p $(dirname ./%); cp % ./%'

# production image

FROM alpine as final

RUN apk add --update git
RUN addgroup -g 1000 -S private-dub && adduser -u 1000 -D -S -G private-dub private-dub

USER private-dub
WORKDIR /home/private-dub

COPY --chown=private-dub:private-dub --from=base /app/private-dub /home/private-dub/
COPY --chown=0:0 --from=base /dist /

ENTRYPOINT ["./private-dub"]
