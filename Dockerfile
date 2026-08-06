FROM busybox:1.37
COPY a.txt /a.txt
RUN cat /a.txt > /b && head -c 1048576 /dev/urandom > /pad && sleep 1
RUN cat /b /a.txt > /c
