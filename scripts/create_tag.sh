#!/bin/bash

tag_name=0.46.8__$(date +%Y-%m-%d_%H-%M-%S)
git tag -a "${tag_name}" -m "${tag_name}"
git push origin "${tag_name}"
