# Dockerfile
# Pierre-André Noël, May 12th 2020
# Copyright © Element AI Inc. All rights reserved.
# Apache License, Version 2.0
#
# See README.md for information and usage.
#
# NOTE:
#   This Dockerfile uses multi-stage builds.
#   https://docs.docker.com/develop/develop-images/multistage-build/


# ******************************************************
# *** All the following images are based on this one ***
# ******************************************************
FROM quay.io/pypa/manylinux2014_x86_64 AS common

# The versions we want in the wheels.
# ENV FST_VERSION "1.8.2"
# ENV PYNINI_VERSION "2.1.5"
ARG FST_VERSION 
ARG PYNINI_VERSION

# ***********************************************************************
# *** Image providing all the requirements for building Pynini wheels ***
# ***********************************************************************
FROM common AS wheel-building-env

# Location of OpenFst and Pynini.
ENV FST_DOWNLOAD_PREFIX "http://www.openfst.org/twiki/pub/FST/FstDownload"
ENV PYNINI_DOWNLOAD_PREFIX "http://www.opengrm.org/twiki/pub/GRM/PyniniDownload"

# Gets and unpack OpenFst source.
RUN yum install -y wget
RUN cd /tmp \
    && wget -q "${FST_DOWNLOAD_PREFIX}/openfst-${FST_VERSION}.tar.gz" \
    && tar -xzf "openfst-${FST_VERSION}.tar.gz" \
    && rm "openfst-${FST_VERSION}.tar.gz"

# Compiles OpenFst.
RUN cd "/tmp/openfst-${FST_VERSION}" \
    && ./configure --enable-grm \
    && make --jobs 4 install \
    && rm -rd "/tmp/openfst-${FST_VERSION}"

# Gets and unpacks Pynini source.
RUN mkdir -p /src && cd /src \
    && wget -q "${PYNINI_DOWNLOAD_PREFIX}/pynini-${PYNINI_VERSION}.tar.gz" \
    && tar -xzf "pynini-${PYNINI_VERSION}.tar.gz" \
    && rm "pynini-${PYNINI_VERSION}.tar.gz"

# Installs requirements in all our Pythons.
ENV PY_VERSION cp310-cp310
ENV PYBIN /opt/python/$PY_VERSION/bin
COPY requirements.txt /src/pynini-${PYNINI_VERSION}/requirements.txt
RUN "${PYBIN}/pip" install --upgrade pip -r "/src/pynini-${PYNINI_VERSION}/requirements.txt" \
    # Use a private package name so that we can upload it to the private repo
    && sed 's/name="pynini"/name="cresta-pynini"/' -i /src/pynini-${PYNINI_VERSION}/setup.py

# **********************************************************
# *** Image making pynini wheels (placed in /wheelhouse) ***
# **********************************************************
FROM wheel-building-env AS build-wheels

# Compiles the wheels to a temporary directory.
RUN "/opt/python/${PY_VERSION}/bin/pip" wheel "/src/pynini-${PYNINI_VERSION}" -w /tmp/wheelhouse/

# Bundles external shared libraries into the wheels.
# See https://github.com/pypa/manylinux/tree/manylinux2014
RUN for WHL in /tmp/wheelhouse/pynini*.whl; do \
    auditwheel repair "${WHL}" -w /wheelhouse/ || exit; \
done

# Copies over Cython wheels.
RUN cp /tmp/wheelhouse/Cython*.whl /wheelhouse

# Removes the non-repaired wheels.
RUN rm -rd /tmp/wheelhouse

# *******************************************************
# *** Installs wheels in a fresh (OpenFst-free) image ***
# *******************************************************
FROM common AS install-pynini-from-wheel

# Grabs the wheels (but just the wheels) from the previous image.
COPY --from=build-wheels /wheelhouse /wheelhouse

# Installs the wheels in all our Pythons.
RUN "${PYBIN}/pip" install pynini --no-index -f /wheelhouse

# ***************************
# *** Runs pynini's tests ***
# ***************************
FROM install-pynini-from-wheel AS run-tests

# Copies Pynini's tests and testing assets.
COPY --from=wheel-building-env "/src/pynini-${PYNINI_VERSION}/tests" /tests

# Runs Pynini's tests for each of our Pythons.
RUN "${PYBIN}/pip" install absl-py || exit; \
    for TEST in tests/*_test.py; do \
        # This test requires external attributes, so we don't bother.
        if [[ "${TEST}" == "tests/chatspeak_model_test.py" ]]; then \
            continue; \
        fi; \
        "${PYBIN}/python" "${TEST}" || exit; \
    done
