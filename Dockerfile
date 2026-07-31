# Build the manager binary
FROM registry.access.redhat.com/ubi9/go-toolset:1.26 as builder

WORKDIR /opt/app-root/src
COPY . .

RUN make build-operator

FROM registry.access.redhat.com/ubi9/ubi-minimal:latest
WORKDIR /
COPY --from=builder /opt/app-root/src/bin/manager .
USER 65532:65532

ENTRYPOINT ["/manager"]
