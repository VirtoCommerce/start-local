FROM nginx:alpine

# nginx/common/snippets/ lands in templates-<mode>/snippets/ and is rendered to conf.d/snippets/, where the server templates include it.
# The compose file picks the template directory (NGINX_ENVSUBST_TEMPLATE_DIR): templates-http, or templates-https with the overlay.
COPY ./nginx/http/ /etc/nginx/templates-http/
COPY ./nginx/common/ /etc/nginx/templates-http/
COPY ./nginx/https/ /etc/nginx/templates-https/
COPY ./nginx/common/ /etc/nginx/templates-https/
COPY ./artifact/default/ /usr/share/nginx/html

EXPOSE 8080
