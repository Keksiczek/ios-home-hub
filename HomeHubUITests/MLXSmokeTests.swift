import XCTest

final class MLXSmokeTests: XCTestCase {
    
    var app: XCUIApplication!
    
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments.append("--use-fake-mlx-loader")
    }
    
    func testMLXColdLoadProgressFlow() {
        // Configure slow loading behavior for the smoke test
        app.launchEnvironment["MLX_LOAD_BEHAVIOR"] = "slow"
        app.launch()
        
        // 1. Navigate to Models (assuming it's a tab or sidebar item)
        // Adjust these queries based on the real app structure.
        let modelsTab = app.tabBars.buttons["Models"]
        if modelsTab.exists {
            modelsTab.tap()
        } else {
            // Fallback for sidebar
            app.buttons["Sidebar"].tap()
            app.buttons["Models"].tap()
        }
        
        // 2. Find an MLX model (using the mock model name)
        let modelRow = app.staticTexts["Llama 3 (Fake MLX)"]
        XCTAssertTrue(modelRow.waitForExistence(timeout: 5), "Mock MLX model should be visible in catalog")
        
        // 3. Start loading
        let loadButton = app.buttons["mlx_load_button"]
        XCTAssertTrue(loadButton.exists, "Load button should be visible for uninstalled MLX model")
        loadButton.tap()
        
        // 4. Verify Download Phase
        let progressBar = app.progressIndicators["mlx_progress_bar"]
        XCTAssertTrue(progressBar.waitForExistence(timeout: 2), "Progress bar should appear during download")
        
        let progressLabel = app.staticTexts["mlx_progress_label"]
        XCTAssertTrue(progressLabel.exists, "Progress percentage label should be visible")
        
        let cancelButton = app.buttons["mlx_cancel_button"]
        XCTAssertTrue(cancelButton.exists, "Cancel button should be visible during download")
        
        // 5. Verify Preparation Phase
        // In "slow" mode, it eventually finishes download and enters preparation.
        let preparingIndicator = app.activityIndicators["mlx_preparing_indicator"]
        XCTAssertTrue(preparingIndicator.waitForExistence(timeout: 10), "Preparing spinner should appear after download")
        
        let preparingLabel = app.staticTexts["mlx_preparing_label"]
        XCTAssertTrue(preparingLabel.exists, "Preparing model... label should be visible")
        
        // 6. Verify Completion
        let unloadButton = app.buttons["mlx_unload_button"]
        XCTAssertTrue(unloadButton.waitForExistence(timeout: 5), "Unload button should appear when model is ready")
    }
    
    func testMLXLoadFailureState() {
        app.launchEnvironment["MLX_LOAD_BEHAVIOR"] = "failure"
        app.launch()
        
        // Navigate to Models
        app.tabBars.buttons["Models"].tap()
        
        app.buttons["mlx_load_button"].tap()
        
        // Verify failure UI
        let retryButton = app.buttons["mlx_retry_button"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 5), "Retry button should appear on failure")
        
        let failureIcon = app.images["exclamationmark.triangle.fill"]
        XCTAssertTrue(failureIcon.exists, "Failure icon should be visible")
    }
    
    func testMLXCancelationFlow() {
        app.launchEnvironment["MLX_LOAD_BEHAVIOR"] = "slow"
        app.launch()
        
        app.tabBars.buttons["Models"].tap()
        
        app.buttons["mlx_load_button"].tap()
        
        let cancelButton = app.buttons["mlx_cancel_button"]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 2))
        cancelButton.tap()
        
        // Verify we returned to idle state
        let loadButton = app.buttons["mlx_load_button"]
        XCTAssertTrue(loadButton.waitForExistence(timeout: 2), "Should return to Load button after cancellation")
        XCTAssertFalse(app.progressIndicators["mlx_progress_bar"].exists)
    }
}
