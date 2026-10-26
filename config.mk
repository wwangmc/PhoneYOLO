# TYPE=0 rootful; TYPE=1 rootless; TYPE=2 RootHide. All targets require iOS 14+.
TYPE ?= 1
DEBUG = 0
FINALPACKAGE = 1
TARGET = iphone:clang:16.5:14.0
ifeq ($(TYPE),0)
ARCHS ?= arm64 arm64e
THEOS_PACKAGE_SCHEME =
else ifeq ($(TYPE),1)
ARCHS ?= arm64 arm64e
THEOS_PACKAGE_SCHEME = rootless
else ifeq ($(TYPE),2)
ARCHS ?= arm64 arm64e
THEOS_PACKAGE_SCHEME = roothide
else
$(error TYPE must be 0, 1 or 2)
endif
