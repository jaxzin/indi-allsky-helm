#!/bin/bash
# Deliberately broken. Throwaway CI non-vacuity control; reverted immediately.
for f in $(ls); do
  rm $f
done
