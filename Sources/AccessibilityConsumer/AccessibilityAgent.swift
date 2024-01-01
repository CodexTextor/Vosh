import AppKit
import Combine
import Foundation
import OSLog

/// Main screen-reader instance.
/// 
/// Only a single instance of this object should be instantiated per screen-reader instance.
@MainActor public final class AccessibilityAgent {
    /// Input listening and tapping instance.
    private let input: AccessibilityInput
    /// Output conveying instance.
    private let output: AccessibilityOutput
    /// Notification center publisher.
    private var notificationStreamHandle: Cancellable!
    /// Notification handling task.
    private var notificationTask: Task<Void, Never>!
    /// Application resolver by process identifier.
    private var applicationRegistry = [pid_t: AccessibilityApplication]()
    /// Process identifier of the currently active application.
    private var activeProcessIdentifier: pid_t = 0

    /// Shortcut to the active application.
    private var activeApplication: AccessibilityApplication? {applicationRegistry[activeProcessIdentifier]}

    /// Creates a new agent.
    public init?() async {
        // Exit before initializing anything unless we have accessibility permissions.
        guard AccessibilityElement.confirmProcessTrustedStatus() else {
            return nil
        }
        input = AccessibilityInput()
        output = AccessibilityOutput()
        setupNotificationListener()
        guard await targetActiveApplication() else {
            return nil
        }
        setupKeyBindings()
    }

    /// Subscribes to application lifecycle event notifications.
    private func setupNotificationListener() {
        let notificationCenter = NSWorkspace.shared.notificationCenter
        let notificationPublisher0 = notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)
        let notificationPublisher1 = notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
        let notificationPublisher2 = notificationCenter.publisher(for: NSWorkspace.didActivateApplicationNotification)
        let notificationPublisher3 = notificationCenter.publisher(for: NSWorkspace.didDeactivateApplicationNotification)
        let notificationPublisher = notificationPublisher0.merge(with: notificationPublisher1, notificationPublisher2, notificationPublisher3).receive(on: RunLoop.main).makeConnectable()
        let notificationStreamHandle = notificationPublisher.connect()
        let notificationStream = notificationPublisher.values.map({($0.name, ($0.userInfo![NSWorkspace.applicationUserInfoKey] as! NSRunningApplication).processIdentifier)})
        notificationTask = Task() {[weak self] in
            for await (notification, processIdentifier) in notificationStream {
                guard let self = self else {
                    return
                }
                await self.handleNotification(notification, processIdentifier: processIdentifier)
            }
        }
        self.notificationStreamHandle = notificationStreamHandle
    }

    /// Targets the currently active application.
    private func targetActiveApplication() async -> Bool {
        guard let runningApplication = NSWorkspace.shared.runningApplications.lazy.filter({$0.isActive}).first else {
            output.conveyNoFocus()
            return true
        }
        let name = runningApplication.localizedName ?? "Application"
        while runningApplication.isActive {
            do {
                let processIdentifier = runningApplication.processIdentifier
                let application = try await AccessibilityApplication(processIdentifier: processIdentifier, input: input)
                applicationRegistry[processIdentifier] = application
                activeProcessIdentifier = runningApplication.processIdentifier
                await application.setActive(output: output)
                break
            } catch AccessibilityError.apiDisabled {
                output.conveyAPIDisabled()
                return false
            } catch AccessibilityError.invalidElement {
                break
            } catch AccessibilityError.notImplemented {
                output.conveyNotAccessible(application: name)
                break
            } catch AccessibilityError.timeout {
                output.conveyNoResponse(application: name)
                continue
            } catch {
                fatalError("Unexpected error creating an application object: \(error.localizedDescription)")
            }
        }
        return true
    }

    /// Binds keys to their respective actions.
    private func setupKeyBindings() {
        input.bindKey(key: .keyboardTab, action: {[weak self] in await self?.activeApplication?.readFocus()})
        input.bindKey(key: .keyboardLeftArrow, action: {[weak self] in await self?.activeApplication?.focusNext(backward: true)})
        input.bindKey(key: .keyboardRightArrow, action: {[weak self] in await self?.activeApplication?.focusNext(backward: false)})
        input.bindKey(key: .keyboardDownArrow, action: {[weak self] in await self?.activeApplication?.enterFocus()})
        input.bindKey(key: .keyboardUpArrow, action: {[weak self] in await self?.activeApplication?.exitFocus()})
        input.bindKey(key: .keyboardPeriodAndRightAngle, action: {[weak self] in await self?.activeApplication?.dump()})
        input.bindKey(key: .keyboardCommaAndLeftAngle, action: {[weak self] in await self?.activeApplication?.dumpFocus()})
        input.bindModifierKey(.leftControl, action: {[weak self] in self?.output.interrupt()})
        input.bindModifierKey(.rightControl, action: {[weak self] in self?.output.interrupt()})
    }

    /// Dispatches application lifecycle notifications to their respective handlers.
    /// - Parameters:
    ///   - notification: Notification name to handle.
    ///   - processIdentifier: PID of the watched process.
    private func handleNotification(_ notification: Notification.Name, processIdentifier: pid_t) async {
        switch notification {
        case NSWorkspace.didLaunchApplicationNotification:
            await applicationDidLaunch(processIdentifier: processIdentifier)
        case NSWorkspace.didTerminateApplicationNotification:
            await applicationDidTerminate(processIdentifier: processIdentifier)
        case NSWorkspace.didActivateApplicationNotification:
            await applicationDidActivate(processIdentifier: processIdentifier)
        case NSWorkspace.didDeactivateApplicationNotification:
            await applicationDidDeactivate(processIdentifier: processIdentifier)
        default:
            fatalError("Received an unexpected notification: \(notification)")
        }
    }

    /// Handles the launching of an application.
    /// - Parameter processIdentifier: PID of the newly launched application.
    private func applicationDidLaunch(processIdentifier: pid_t) async {}

    /// Handles the termination of an application.
    /// - Parameter processIdentifier: PID of the terminated application.
    private func applicationDidTerminate(processIdentifier: pid_t) async {
        applicationRegistry[processIdentifier] = nil
        if activeProcessIdentifier == processIdentifier {
            activeProcessIdentifier = 0
        }
    }

    /// Handles the activation of an application.
    /// - Parameter processIdentifier: PID of the activated application.
    private func applicationDidActivate(processIdentifier: pid_t) async {
        guard let application = applicationRegistry[processIdentifier] else {
            guard let runningApplication = NSRunningApplication(processIdentifier: processIdentifier) else {
                return
            }
            while runningApplication.isActive {
                do {
                    let processIdentifier = runningApplication.processIdentifier
                    let application = try await AccessibilityApplication(processIdentifier: processIdentifier, input: input)
                    applicationRegistry[processIdentifier] = application
                    await application.setActive(output: output)
                    activeProcessIdentifier = processIdentifier
                    return
                } catch AccessibilityError.apiDisabled {
                    output.conveyAPIDisabled()
                    return
                } catch AccessibilityError.invalidElement {
                    return
                } catch AccessibilityError.notImplemented {
                    output.conveyNotAccessible(application: runningApplication.localizedName ?? "Unnamed application")
                    return
                } catch AccessibilityError.timeout {
                    output.conveyNoResponse(application: runningApplication.localizedName ?? "UnnamedApplication")
                    continue
                } catch {
                    fatalError("Unexpected error creating an application object: \(error.localizedDescription)")
                }
            }
            return
        }
        if activeProcessIdentifier != processIdentifier {
            await application.setActive(output: output)
            activeProcessIdentifier = processIdentifier
        }
    }

    /// Handles the deactivation of an application.
    /// - Parameter processIdentifier: PID of the deactivated application.
    private func applicationDidDeactivate(processIdentifier: pid_t) async {
        guard let application = applicationRegistry[processIdentifier] else {
            return
        }
        await application.clearActive()
        if activeProcessIdentifier == processIdentifier {
            activeProcessIdentifier = 0
        }
    }

    deinit {
        notificationStreamHandle.cancel()
        notificationTask.cancel()
    }
}