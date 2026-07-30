FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive

# Runtime essentials
RUN apt-get update && apt-get install -y \
    ca-certificates \
    curl \
    git \
    jq \
    sudo \
    unzip \
    wget \
    && rm -rf /var/lib/apt/lists/*

# --- Optional: Android SDK + JDK ---
# Uncomment and adjust versions as needed.
#
# ENV ANDROID_HOME=/opt/android-sdk
# ENV JAVA_HOME=/usr/lib/jvm/temurin-22-jdk-amd64
# ENV PATH=$JAVA_HOME/bin:$PATH:$ANDROID_HOME/cmdline-tools/latest/bin:$ANDROID_HOME/platform-tools
#
# RUN apt-get update && apt-get install -y ca-certificates curl && \
#     mkdir -p /etc/apt/keyrings && \
#     curl -fsSL https://packages.adoptium.net/artifactory/api/gpg/key/public \
#         | tee /etc/apt/keyrings/adoptium.asc && \
#     echo "deb [signed-by=/etc/apt/keyrings/adoptium.asc] \
#         https://packages.adoptium.net/artifactory/deb \
#         $(awk -F= '/VERSION_CODENAME/{print$2}' /etc/os-release) main" \
#         | tee /etc/apt/sources.list.d/adoptium.list && \
#     apt-get update && apt-get install -y \
#         temurin-22-jdk \
#         libicu74 \
#         libssl3t64 \
#         liblttng-ust1t64 \
#     && rm -rf /var/lib/apt/lists/*
#
# RUN mkdir -p $ANDROID_HOME/cmdline-tools
# RUN wget https://dl.google.com/android/repository/commandlinetools-linux-14742923_latest.zip \
#     -O /tmp/tools.zip
# RUN unzip /tmp/tools.zip -d /tmp
# RUN mv /tmp/cmdline-tools $ANDROID_HOME/cmdline-tools/latest
# RUN yes | sdkmanager --licenses
# RUN sdkmanager \
#     "platform-tools" \
#     "platforms;android-36" \
#     "build-tools;36.0.0"

# GitHub Actions runner
RUN mkdir /actions-runner
WORKDIR /actions-runner

RUN curl -L \
    https://github.com/actions/runner/releases/download/v2.336.0/actions-runner-linux-x64-2.336.0.tar.gz \
    -o actions-runner.tar.gz && \
    tar xzf actions-runner.tar.gz && \
    rm actions-runner.tar.gz

# runner user with passwordless sudo (needed for things like KVM setup)
RUN useradd -m runner && \
    usermod -aG sudo runner && \
    echo "runner ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/runner && \
    chmod 440 /etc/sudoers.d/runner && \
    chown -R runner:runner /actions-runner && \
    mkdir -p /home/runner/.gradle && \
    chown -R runner:runner /home/runner/.gradle

COPY entrypoint.sh .
RUN chmod +x entrypoint.sh

USER runner

ENTRYPOINT ["./entrypoint.sh"]
