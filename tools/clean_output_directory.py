#!/usr/bin/env python
#
# Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
# for details. All rights reserved. Use of this source code is governed by a
# BSD-style license that can be found in the LICENSE file.
#

import optparse
import shutil
import sys
import utils

HOST_OS = utils.GuessOS()

def BuildOptions():
  result = optparse.OptionParser()
  result.add_option("-m", "--mode",
      help='Build variants (comma-separated).',
      metavar='[all,debug,release]',
      default='debug')
  result.add_option("--arch",
      help='Target architectures (comma-separated).',
      metavar='[all,ia32,x64,simarm,arm]',
      default=utils.GuessArchitecture())
  return result

def ProcessOptions(options):
  if options.arch == 'all':
    options.arch = 'ia32,x64'
  if options.mode == 'all':
    options.mode = 'release,debug'
  options.mode = options.mode.split(',')
  options.arch = options.arch.split(',')
  for mode in options.mode:
    if not mode in ['debug', 'release']:
      print "Unknown mode %s" % mode
      return False
  for arch in options.arch:
    if not arch in ['ia32', 'x64', 'simarm', 'arm']:
      print "Unknown arch %s" % arch
      return False
  return True

def Main():
  parser = BuildOptions()
  (options, args) = parser.parse_args()
  if not ProcessOptions(options):
    parser.print_help()
    return 1

  # Delete the output for the targets for each requested configuration.
  for mode in options.mode:
    for arch in options.arch:
      build_root = utils.GetBuildRoot(HOST_OS, mode=mode, arch=arch)
      print "Deleting %s" % (build_root)
      shutil.rmtree(build_root, ignore_errors=True)
      # On windows we have additional object files within the runtime library.
      if HOST_OS == 'win32':
        runtime_root = 'runtime/' + build_root
        print "Deleting %s" % (runtime_root)
        shutil.rmtree(runtime_root, ignore_errors=True)
  return 0

if __name__ == '__main__':
  sys.exit(Main())
