// CollectionTests.swift
// RockitKit — Rockit Language Compiler
// Copyright © 2026 Dark Matter Tech. All rights reserved.

import XCTest
@testable import RockitKit

final class CollectionTests: XCTestCase {

    private var heap: Heap!
    private var arc: ReferenceCounter!
    private var builtins: BuiltinRegistry!

    override func setUp() {
        super.setUp()
        heap = Heap()
        arc = ReferenceCounter(heap: heap)
        builtins = BuiltinRegistry()
        builtins.registerCollectionBuiltins(heap: heap, arc: arc)
    }

    // MARK: - Helpers

    private func call(_ name: String, _ args: [Value]) throws -> Value {
        guard let fn = builtins.lookup(name) else {
            XCTFail("Builtin '\(name)' not registered")
            return .null
        }
        return try fn(args)
    }

    // MARK: - List Creation

    func testListCreate() throws {
        let result = try call("listCreate", [])
        guard case .objectRef(let id) = result else {
            XCTFail("Expected objectRef"); return
        }
        let obj = try heap.get(id)
        XCTAssertEqual(obj.typeName, "List")
        XCTAssertNotNil(obj.listStorage)
        XCTAssertEqual(obj.listStorage?.count, 0)
    }

    // MARK: - List Append and Get

    func testListAppendAndGet() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(10)])
        _ = try call("listAppend", [list, .int(20)])
        _ = try call("listAppend", [list, .int(30)])

        XCTAssertEqual(try call("listGet", [list, .int(0)]), .int(10))
        XCTAssertEqual(try call("listGet", [list, .int(1)]), .int(20))
        XCTAssertEqual(try call("listGet", [list, .int(2)]), .int(30))
    }

    func testListAppendMixedTypes() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(1)])
        _ = try call("listAppend", [list, .string("hello")])
        _ = try call("listAppend", [list, .bool(true)])
        _ = try call("listAppend", [list, .null])

        XCTAssertEqual(try call("listGet", [list, .int(0)]), .int(1))
        XCTAssertEqual(try call("listGet", [list, .int(1)]), .string("hello"))
        XCTAssertEqual(try call("listGet", [list, .int(2)]), .bool(true))
        XCTAssertEqual(try call("listGet", [list, .int(3)]), .null)
    }

    // MARK: - List Size

    func testListSize() throws {
        let list = try call("listCreate", [])
        XCTAssertEqual(try call("listSize", [list]), .int(0))
        _ = try call("listAppend", [list, .string("a")])
        XCTAssertEqual(try call("listSize", [list]), .int(1))
        _ = try call("listAppend", [list, .string("b")])
        XCTAssertEqual(try call("listSize", [list]), .int(2))
    }

    // MARK: - List Set

    func testListSet() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(10)])
        _ = try call("listAppend", [list, .int(20)])
        _ = try call("listSet", [list, .int(0), .int(99)])
        XCTAssertEqual(try call("listGet", [list, .int(0)]), .int(99))
        XCTAssertEqual(try call("listGet", [list, .int(1)]), .int(20))
    }

    func testListSetArcWriteBarrier() throws {
        let objId = heap.allocate(typeName: "TestObj")
        // objId has refCount=1 from allocation

        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .objectRef(objId)])
        // append retains, so refCount=2
        XCTAssertEqual(heap.refCount(of: objId), 2)

        // Set replaces the element — should release the old objectRef
        _ = try call("listSet", [list, .int(0), .int(42)])
        // objId should have been released by set, refCount=1
        XCTAssertEqual(heap.refCount(of: objId), 1)
    }

    // MARK: - List RemoveAt

    func testListRemoveAt() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .string("a")])
        _ = try call("listAppend", [list, .string("b")])
        _ = try call("listAppend", [list, .string("c")])

        let removed = try call("listRemoveAt", [list, .int(1)])
        XCTAssertEqual(removed, .string("b"))
        XCTAssertEqual(try call("listSize", [list]), .int(2))
        XCTAssertEqual(try call("listGet", [list, .int(0)]), .string("a"))
        XCTAssertEqual(try call("listGet", [list, .int(1)]), .string("c"))
    }

    // MARK: - List Contains

    func testListContains() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(10)])
        _ = try call("listAppend", [list, .int(20)])

        XCTAssertEqual(try call("listContains", [list, .int(10)]), .bool(true))
        XCTAssertEqual(try call("listContains", [list, .int(20)]), .bool(true))
        XCTAssertEqual(try call("listContains", [list, .int(30)]), .bool(false))
    }

    // MARK: - List IndexOf

    func testListIndexOf() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .string("x")])
        _ = try call("listAppend", [list, .string("y")])
        _ = try call("listAppend", [list, .string("z")])

        XCTAssertEqual(try call("listIndexOf", [list, .string("y")]), .int(1))
        XCTAssertEqual(try call("listIndexOf", [list, .string("z")]), .int(2))
        XCTAssertEqual(try call("listIndexOf", [list, .string("w")]), .int(-1))
    }

    // MARK: - List IsEmpty

    func testListIsEmpty() throws {
        let list = try call("listCreate", [])
        XCTAssertEqual(try call("listIsEmpty", [list]), .bool(true))
        _ = try call("listAppend", [list, .int(1)])
        XCTAssertEqual(try call("listIsEmpty", [list]), .bool(false))
    }

    // MARK: - List Clear

    func testListClear() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(1)])
        _ = try call("listAppend", [list, .int(2)])
        _ = try call("listAppend", [list, .int(3)])
        _ = try call("listClear", [list])
        XCTAssertEqual(try call("listSize", [list]), .int(0))
        XCTAssertEqual(try call("listIsEmpty", [list]), .bool(true))
    }

    func testListClearReleasesObjectRefs() throws {
        let obj1 = heap.allocate(typeName: "Obj1")
        let obj2 = heap.allocate(typeName: "Obj2")

        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .objectRef(obj1)])
        _ = try call("listAppend", [list, .objectRef(obj2)])
        // Each object: refCount=2 (alloc + list)
        XCTAssertEqual(heap.refCount(of: obj1), 2)
        XCTAssertEqual(heap.refCount(of: obj2), 2)

        _ = try call("listClear", [list])
        // After clear, list released its refs: refCount=1 each
        XCTAssertEqual(heap.refCount(of: obj1), 1)
        XCTAssertEqual(heap.refCount(of: obj2), 1)
    }

    // MARK: - List Bounds Errors

    func testListGetOutOfBounds() throws {
        let list = try call("listCreate", [])
        XCTAssertThrowsError(try call("listGet", [list, .int(0)])) { error in
            if case VMError.indexOutOfBounds = error {} else {
                XCTFail("Expected indexOutOfBounds, got \(error)")
            }
        }
    }

    func testListGetNegativeIndex() throws {
        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .int(42)])
        XCTAssertThrowsError(try call("listGet", [list, .int(-1)])) { error in
            if case VMError.indexOutOfBounds = error {} else {
                XCTFail("Expected indexOutOfBounds, got \(error)")
            }
        }
    }

    func testListSetOutOfBounds() throws {
        let list = try call("listCreate", [])
        XCTAssertThrowsError(try call("listSet", [list, .int(0), .int(99)])) { error in
            if case VMError.indexOutOfBounds = error {} else {
                XCTFail("Expected indexOutOfBounds, got \(error)")
            }
        }
    }

    // MARK: - List ARC Cascading Release

    func testListDeallocReleasesElements() throws {
        let inner1 = heap.allocate(typeName: "Inner")
        let inner2 = heap.allocate(typeName: "Inner")

        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, .objectRef(inner1)])
        _ = try call("listAppend", [list, .objectRef(inner2)])
        // inner1 refCount=2, inner2 refCount=2

        // Release "local" refs to inner objects
        arc.release(.objectRef(inner1))  // refCount=1 (only list holds it)
        arc.release(.objectRef(inner2))  // refCount=1 (only list holds it)

        // Release the list → cascading release should free inner1 and inner2
        arc.release(list)

        XCTAssertEqual(heap.liveObjectCount, 0, "All objects should be deallocated")
    }

    // MARK: - List Type Mismatch

    func testListOperationOnNonList() throws {
        XCTAssertThrowsError(try call("listAppend", [.int(42), .int(1)])) { error in
            if case VMError.typeMismatch = error {} else {
                XCTFail("Expected typeMismatch, got \(error)")
            }
        }
    }

    func testListOperationOnNull() throws {
        XCTAssertThrowsError(try call("listAppend", [.null, .int(1)])) { error in
            if case VMError.typeMismatch = error {} else {
                XCTFail("Expected typeMismatch, got \(error)")
            }
        }
    }

    // MARK: - HashMap Creation

    func testMapCreate() throws {
        let result = try call("mapCreate", [])
        guard case .objectRef(let id) = result else {
            XCTFail("Expected objectRef"); return
        }
        let obj = try heap.get(id)
        XCTAssertEqual(obj.typeName, "HashMap")
        XCTAssertNotNil(obj.mapStorage)
        XCTAssertEqual(obj.mapStorage?.count, 0)
    }

    // MARK: - HashMap Put and Get

    func testMapPutAndGet() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("name"), .string("Alice")])
        _ = try call("mapPut", [map, .string("age"), .int(30)])

        XCTAssertEqual(try call("mapGet", [map, .string("name")]), .string("Alice"))
        XCTAssertEqual(try call("mapGet", [map, .string("age")]), .int(30))
    }

    func testMapGetMissingKeyReturnsNull() throws {
        let map = try call("mapCreate", [])
        XCTAssertEqual(try call("mapGet", [map, .string("missing")]), .null)
    }

    func testMapPutWithIntKeys() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .int(1), .string("one")])
        _ = try call("mapPut", [map, .int(2), .string("two")])

        XCTAssertEqual(try call("mapGet", [map, .int(1)]), .string("one"))
        XCTAssertEqual(try call("mapGet", [map, .int(2)]), .string("two"))
    }

    // MARK: - HashMap Put Overwrite

    func testMapPutOverwrite() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("key"), .int(1)])
        _ = try call("mapPut", [map, .string("key"), .int(2)])

        XCTAssertEqual(try call("mapGet", [map, .string("key")]), .int(2))
        XCTAssertEqual(try call("mapSize", [map]), .int(1))
    }

    func testMapPutOverwriteReleasesOldValue() throws {
        let oldObj = heap.allocate(typeName: "OldVal")
        let newObj = heap.allocate(typeName: "NewVal")

        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("k"), .objectRef(oldObj)])
        // oldObj: refCount=2 (alloc + map)
        XCTAssertEqual(heap.refCount(of: oldObj), 2)

        _ = try call("mapPut", [map, .string("k"), .objectRef(newObj)])
        // oldObj: released by overwrite, refCount=1
        // newObj: retained by map, refCount=2
        XCTAssertEqual(heap.refCount(of: oldObj), 1)
        XCTAssertEqual(heap.refCount(of: newObj), 2)
    }

    // MARK: - HashMap Remove

    func testMapRemove() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("a"), .int(1)])
        _ = try call("mapPut", [map, .string("b"), .int(2)])

        let removed = try call("mapRemove", [map, .string("a")])
        XCTAssertEqual(removed, .int(1))
        XCTAssertEqual(try call("mapSize", [map]), .int(1))
        XCTAssertEqual(try call("mapGet", [map, .string("a")]), .null)
    }

    func testMapRemoveMissingKey() throws {
        let map = try call("mapCreate", [])
        let result = try call("mapRemove", [map, .string("missing")])
        XCTAssertEqual(result, .null)
    }

    // MARK: - HashMap ContainsKey

    func testMapContainsKey() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .int(42), .string("answer")])

        XCTAssertEqual(try call("mapContainsKey", [map, .int(42)]), .bool(true))
        XCTAssertEqual(try call("mapContainsKey", [map, .int(99)]), .bool(false))
    }

    // MARK: - HashMap Keys and Values

    func testMapKeys() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("a"), .int(1)])
        _ = try call("mapPut", [map, .string("b"), .int(2)])

        let keysList = try call("mapKeys", [map])
        XCTAssertEqual(try call("listSize", [keysList]), .int(2))

        // Keys should contain both "a" and "b"
        XCTAssertEqual(try call("listContains", [keysList, .string("a")]), .bool(true))
        XCTAssertEqual(try call("listContains", [keysList, .string("b")]), .bool(true))
    }

    func testMapValues() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("x"), .int(10)])
        _ = try call("mapPut", [map, .string("y"), .int(20)])

        let valuesList = try call("mapValues", [map])
        XCTAssertEqual(try call("listSize", [valuesList]), .int(2))

        XCTAssertEqual(try call("listContains", [valuesList, .int(10)]), .bool(true))
        XCTAssertEqual(try call("listContains", [valuesList, .int(20)]), .bool(true))
    }

    // MARK: - HashMap Size, IsEmpty, Clear

    func testMapSizeAndIsEmpty() throws {
        let map = try call("mapCreate", [])
        XCTAssertEqual(try call("mapSize", [map]), .int(0))
        XCTAssertEqual(try call("mapIsEmpty", [map]), .bool(true))

        _ = try call("mapPut", [map, .string("k"), .int(1)])
        XCTAssertEqual(try call("mapSize", [map]), .int(1))
        XCTAssertEqual(try call("mapIsEmpty", [map]), .bool(false))
    }

    func testMapClear() throws {
        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("a"), .int(1)])
        _ = try call("mapPut", [map, .string("b"), .int(2)])
        _ = try call("mapClear", [map])
        XCTAssertEqual(try call("mapSize", [map]), .int(0))
        XCTAssertEqual(try call("mapIsEmpty", [map]), .bool(true))
    }

    func testMapClearReleasesKeysAndValues() throws {
        let keyObj = heap.allocate(typeName: "Key")
        let valObj = heap.allocate(typeName: "Val")

        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .objectRef(keyObj), .objectRef(valObj)])
        // Both refCount=2 (alloc + map)
        XCTAssertEqual(heap.refCount(of: keyObj), 2)
        XCTAssertEqual(heap.refCount(of: valObj), 2)

        _ = try call("mapClear", [map])
        // After clear, refCount=1 each (only alloc ref remains)
        XCTAssertEqual(heap.refCount(of: keyObj), 1)
        XCTAssertEqual(heap.refCount(of: valObj), 1)
    }

    // MARK: - HashMap ARC Cascading Release

    func testMapDeallocReleasesKeysAndValues() throws {
        let keyObj = heap.allocate(typeName: "Key")
        let valObj = heap.allocate(typeName: "Val")

        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .objectRef(keyObj), .objectRef(valObj)])

        // Release "local" references
        arc.release(.objectRef(keyObj))   // refCount=1 (only map holds it)
        arc.release(.objectRef(valObj))   // refCount=1 (only map holds it)

        // Release the map → cascading release should free key and value objects
        arc.release(map)

        XCTAssertEqual(heap.liveObjectCount, 0, "All objects should be deallocated")
    }

    // MARK: - HashMap Type Mismatch

    func testMapOperationOnNonMap() throws {
        XCTAssertThrowsError(try call("mapPut", [.string("not a map"), .int(1), .int(2)])) { error in
            if case VMError.typeMismatch = error {} else {
                XCTFail("Expected typeMismatch, got \(error)")
            }
        }
    }

    // MARK: - Nested Collections

    func testListOfMaps() throws {
        let map1 = try call("mapCreate", [])
        _ = try call("mapPut", [map1, .string("id"), .int(1)])

        let map2 = try call("mapCreate", [])
        _ = try call("mapPut", [map2, .string("id"), .int(2)])

        let list = try call("listCreate", [])
        _ = try call("listAppend", [list, map1])
        _ = try call("listAppend", [list, map2])

        let retrieved = try call("listGet", [list, .int(0)])
        XCTAssertEqual(try call("mapGet", [retrieved, .string("id")]), .int(1))

        let retrieved2 = try call("listGet", [list, .int(1)])
        XCTAssertEqual(try call("mapGet", [retrieved2, .string("id")]), .int(2))
    }

    func testMapOfLists() throws {
        let list1 = try call("listCreate", [])
        _ = try call("listAppend", [list1, .int(10)])
        _ = try call("listAppend", [list1, .int(20)])

        let map = try call("mapCreate", [])
        _ = try call("mapPut", [map, .string("numbers"), list1])

        let retrieved = try call("mapGet", [map, .string("numbers")])
        XCTAssertEqual(try call("listGet", [retrieved, .int(0)]), .int(10))
        XCTAssertEqual(try call("listSize", [retrieved]), .int(2))
    }
}
