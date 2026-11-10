FROM nginx:alpine

# nginx/common/snippets/ lands in templates-http/snippets/ and is rendered to conf.d/snippets/, where the server templates include it.
COPY ./nginx/http/ /etc/nginx/templates-http/
COPY ./nginx/common/ /etc/nginx/templates-http/
COPY ./artifact/default/ /usr/share/nginx/html

EXPOSE 8080
