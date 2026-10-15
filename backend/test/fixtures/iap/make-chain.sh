#!/bin/sh
# Throwaway CA chain shaped like Apple's StoreKit signing chain (root → intermediate → leaf with the
# receipt-signing extension), for purchase.test.mjs. Not trusted by anything. Regenerate with:
#   sh test/fixtures/iap/make-chain.sh test/fixtures/iap
set -e
D="$1"; cd "$D"
openssl ecparam -name prime256v1 -genkey -noout -out root.key
openssl req -x509 -new -key root.key -subj "/CN=Test Root" -days 36500 -out root.pem \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign"
openssl ecparam -name prime256v1 -genkey -noout -out int.key
openssl req -new -key int.key -subj "/CN=Test Intermediate" -out int.csr
printf "basicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign\n" > int.ext
openssl x509 -req -in int.csr -CA root.pem -CAkey root.key -CAcreateserial -days 36500 -extfile int.ext -out int.pem
openssl ecparam -name prime256v1 -genkey -noout -out leaf.key
openssl req -new -key leaf.key -subj "/CN=Test StoreKit Signing" -out leaf.csr
printf "1.2.840.113635.100.6.11.1=ASN1:NULL\n" > leaf.ext
openssl x509 -req -in leaf.csr -CA int.pem -CAkey int.key -CAcreateserial -days 36500 -extfile leaf.ext -out leaf.pem
openssl pkcs8 -topk8 -nocrypt -in leaf.key -out leaf.pk8
rm -f *.csr *.ext *.srl root.key int.key leaf.key
