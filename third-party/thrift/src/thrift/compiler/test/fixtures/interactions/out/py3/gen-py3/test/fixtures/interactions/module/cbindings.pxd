#
# Autogenerated by Thrift for thrift/compiler/test/fixtures/interactions/src/module.thrift
#
# DO NOT EDIT UNLESS YOU ARE SURE THAT YOU KNOW WHAT YOU ARE DOING
#  @generated
#
from libc.stdint cimport (
    int8_t as cint8_t,
    int16_t as cint16_t,
    int32_t as cint32_t,
    int64_t as cint64_t,
    uint16_t as cuint16_t,
    uint32_t as cuint32_t,
)
from libcpp.string cimport string
from libcpp cimport bool as cbool, nullptr, nullptr_t
from cpython cimport bool as pbool
from libcpp.memory cimport shared_ptr, unique_ptr
from libcpp.vector cimport vector
from libcpp.set cimport set as cset
from libcpp.map cimport map as cmap, pair as cpair
from libcpp.unordered_map cimport unordered_map as cumap
cimport folly.iobuf as _fbthrift_iobuf
from thrift.python.exceptions cimport cTException
from thrift.py3.types cimport (
    bstring,
    field_ref as __field_ref,
    optional_field_ref as __optional_field_ref,
    required_field_ref as __required_field_ref,
    terse_field_ref as __terse_field_ref,
    union_field_ref as __union_field_ref,
    get_union_field_value as __get_union_field_value,
)
from thrift.python.common cimport cThriftMetadata as __fbthrift_cThriftMetadata

cimport test.fixtures.another_interactions.shared.cbindings as _test_fixtures_another_interactions_shared_cbindings


cdef extern from "thrift/compiler/test/fixtures/interactions/gen-cpp2/module_metadata.h" namespace "apache::thrift::detail::md":
    cdef cppclass ExceptionMetadata[T]:
        @staticmethod
        void gen(__fbthrift_cThriftMetadata &metadata)
cdef extern from "thrift/compiler/test/fixtures/interactions/gen-cpp2/module_metadata.h" namespace "apache::thrift::detail::md":
    cdef cppclass StructMetadata[T]:
        @staticmethod
        void gen(__fbthrift_cThriftMetadata &metadata)
cdef extern from "thrift/compiler/test/fixtures/interactions/gen-cpp2/module_types_custom_protocol.h" namespace "::cpp2":

    cdef cppclass cCustomException "::cpp2::CustomException"(cTException):
        cCustomException() except +
        cCustomException(const cCustomException&) except +
        bint operator==(cCustomException&)
        bint operator!=(cCustomException&)
        bint operator<(cCustomException&)
        bint operator>(cCustomException&)
        bint operator<=(cCustomException&)
        bint operator>=(cCustomException&)
        __field_ref[string] message_ref "message_ref" ()


    cdef cppclass cShouldBeBoxed "::cpp2::ShouldBeBoxed":
        cShouldBeBoxed() except +
        cShouldBeBoxed(const cShouldBeBoxed&) except +
        bint operator==(cShouldBeBoxed&)
        bint operator!=(cShouldBeBoxed&)
        bint operator<(cShouldBeBoxed&)
        bint operator>(cShouldBeBoxed&)
        bint operator<=(cShouldBeBoxed&)
        bint operator>=(cShouldBeBoxed&)
        __field_ref[string] sessionId_ref "sessionId_ref" ()

