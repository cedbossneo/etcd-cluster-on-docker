FROM        alpine:latest
RUN         apk add --update bash ca-certificates openssl tar drill net-tools curl netcat-openbsd && \
            wget https://github.com/coreos/etcd/releases/download/v3.0.8/etcd-v3.0.8-linux-amd64.tar.gz && \
            tar xzvf etcd-v3.0.8-linux-amd64.tar.gz && \
            mv etcd-v3.0.8-linux-amd64/etcd* /bin/ && \
            apk del --purge tar openssl && \
            rm -Rf etcd-v3.0.8-linux-amd64* /var/cache/apk/*
EXPOSE      2379 2380
ADD         /bin/etcd_init.sh /bin/etcd_init.sh
ADD         /bin/etcd_proxy.sh /bin/etcd_proxy.sh
RUN         chmod +x /bin/etcd_init.sh /bin/etcd_proxy.sh
CMD         ["/bin/etcd_init.sh"]
