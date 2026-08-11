import XCTest

final class ObjCExceptionCatcherTests: XCTestCase {
    private struct SampleError: Error, Equatable {
        let id: Int
    }

    func testRaisedNSExceptionBecomesObjCExceptionError() {
        do {
            try catchingObjCExceptions {
                NSException(
                    name: .invalidArgumentException,
                    reason: "Failed to create tap due to format mismatch",
                    userInfo: nil
                ).raise()
            }
            XCTFail("Expected the raised NSException to be thrown as an error")
        } catch let error as ObjCExceptionError {
            XCTAssertEqual(error.name, NSExceptionName.invalidArgumentException.rawValue)
            XCTAssertEqual(error.reason, "Failed to create tap due to format mismatch")
        } catch {
            XCTFail("Expected ObjCExceptionError, got \(error)")
        }
    }

    func testReturnsValueWhenNothingRaises() throws {
        let value = try catchingObjCExceptions { 42 }
        XCTAssertEqual(value, 42)
    }

    func testSwiftErrorPassesThroughUnwrapped() {
        do {
            try catchingObjCExceptions { throw SampleError(id: 7) }
            XCTFail("Expected the Swift error to propagate")
        } catch let error as SampleError {
            XCTAssertEqual(error, SampleError(id: 7))
        } catch {
            XCTFail("Expected SampleError, got \(error)")
        }
    }

    func testNilReasonMapsToUnknown() {
        do {
            try catchingObjCExceptions {
                NSException(name: .genericException, reason: nil, userInfo: nil).raise()
            }
            XCTFail("Expected the raised NSException to be thrown as an error")
        } catch let error as ObjCExceptionError {
            XCTAssertEqual(error.reason, "unknown")
        } catch {
            XCTFail("Expected ObjCExceptionError, got \(error)")
        }
    }
}
