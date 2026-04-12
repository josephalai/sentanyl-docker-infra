# We specify the base image we need for our
# go application
FROM golang:1.25

# Add Maintainer Info
LABEL maintainer="Joseph Alai <joseph@sovrinmind.com>"

RUN apt-get update && apt-get install -y psmisc && apt-get install -y fswatch
