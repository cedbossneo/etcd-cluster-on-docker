FROM        alpine:latest
RUN         apk add --update bash ca-certificates openssl tar drill net-tools netcat-openbsd && \
            wget https://github.com/coreos/etcd/releases/download/v3.0.7/etcd-v3.0.7-linux-amd64.tar.gz && \
            tar xzvf etcd-v3.0.7-linux-amd64.tar.gz && \
            mv etcd-v3.0.7-linux-amd64/etcd* /bin/ && \
            apk del --purge tar openssl && \
            rm -Rf etcd-v3.0.7-linux-amd64* /var/cache/apk/*
EXPOSE      2379 2380
ADD         /bin/etcd_init.sh /bin/etcd_init.sh
RUN         chmod +x /bin/etcd_init.sh
CMD         ["/bin/etcd_init.sh"]            
