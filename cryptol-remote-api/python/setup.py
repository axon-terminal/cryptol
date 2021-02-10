#!/usr/bin/env python
# -*- coding: utf-8 -*-

from setuptools import setup

def get_README():
    content = ""
    with open("README.md") as f:
        content += f.read()
    return content

setup(
    name="cryptol",
    python_requires=">=3.7",
    version="0.0.1",
    url="https://github.com/GaloisInc/cryptol",
    project_urls={
        "Changelog": "https://github.com/GaloisInc/cryptol/tree/master/cryptol-remote-api/python/CHANGELOG.md",
        "Source": "hhttps://github.com/GaloisInc/cryptol/tree/master/cryptol-remote-api/python",
        "Bug Tracker": "https://github.com/GaloisInc/cryptol/issues"
    },
    license="BSD",
    description="A Python Cryptol library for interacting with the Cryptol RPC server.",
    long_description=get_README(),
    long_description_content_type="text/markdown",
    author="Galois, Inc.",
    author_email="andrew@galois.com",
    packages=["cryptol"],
    package_data={"cryptol": ["py.typed"]},
    zip_safe=False,
    install_requires=[
        "BitVector==3.4.9",
        "mypy==0.790",
        "mypy-extensions==0.4.3",
        "argo-client==0.0.3"
    ],
    classifiers=[
        "Development Status :: 3 - Alpha",
        "License :: OSI Approved :: BSD License",
        "Operating System :: OS Independent",
        "Programming Language :: Python :: 3.7",
        "Programming Language :: Python :: 3.8",
        "Programming Language :: Python :: 3.9"
    ],
)
