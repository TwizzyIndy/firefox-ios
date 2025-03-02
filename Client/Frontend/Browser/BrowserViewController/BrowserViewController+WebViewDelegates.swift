// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at http://mozilla.org/MPL/2.0

import Foundation
import Common
import WebKit
import Shared
import UIKit

/// List of schemes that are allowed to be opened in new tabs.
private let schemesAllowedToBeOpenedAsPopups = ["http", "https", "javascript", "data", "about"]

// MARK: - WKUIDelegate
extension BrowserViewController: WKUIDelegate {
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard let parentTab = tabManager[webView] else { return nil }
        guard !navigationAction.isInternalUnprivileged,
              shouldRequestBeOpenedAsPopup(navigationAction.request)
        else {
            guard let url = navigationAction.request.url else { return nil }

            if url.scheme == "whatsapp" && UIApplication.shared.canOpenURL(url) {
                UIApplication.shared.open(url, options: [:])
            }

            return nil
        }

        if let currentTab = tabManager.selectedTab {
            screenshotHelper.takeScreenshot(currentTab)
        }

        // If the page uses `window.open()` or `[target="_blank"]`, open the page in a new tab.
        // IMPORTANT!!: WebKit will perform the `URLRequest` automatically!! Attempting to do
        // the request here manually leads to incorrect results!!
        let newTab = tabManager.addPopupForParentTab(profile: profile, parentTab: parentTab, configuration: configuration)

        newTab.url = URL(string: "about:blank")

        return newTab.webView
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptAlertPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping () -> Void
    ) {
        let shouldShowAlert = shouldDisplayJSAlertForWebView(webView)
        let messageAlert = MessageAlert(message: message,
                                        frame: frame,
                                        completionHandler: completionHandler,
                                        shouldCallCompletion: shouldShowAlert)
        if shouldShowAlert {
            present(messageAlert.alertController(), animated: true, completion: nil)
        } else if let promptingTab = tabManager[webView] {
            promptingTab.queueJavascriptAlertPrompt(messageAlert)
            completionHandler()
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptConfirmPanelWithMessage message: String,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (Bool) -> Void
    ) {
        let shouldShowAlert = shouldDisplayJSAlertForWebView(webView)
        let confirmAlert = ConfirmPanelAlert(message: message,
                                             frame: frame,
                                             completionHandler: completionHandler,
                                             shouldCallCompletion: shouldShowAlert)
        if shouldDisplayJSAlertForWebView(webView) {
            present(confirmAlert.alertController(), animated: true, completion: nil)
        } else if let promptingTab = tabManager[webView] {
            promptingTab.queueJavascriptAlertPrompt(confirmAlert)
            completionHandler(false)
        }
    }

    func webView(
        _ webView: WKWebView,
        runJavaScriptTextInputPanelWithPrompt prompt: String,
        defaultText: String?,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping (String?) -> Void
    ) {
        let shouldShowAlert = shouldDisplayJSAlertForWebView(webView)
        let textInputAlert = TextInputAlert(message: prompt,
                                            frame: frame,
                                            completionHandler: completionHandler,
                                            defaultText: defaultText,
                                            shouldCallCompletion: shouldShowAlert)
        if shouldDisplayJSAlertForWebView(webView) {
            present(textInputAlert.alertController(), animated: true, completion: nil)
        } else if let promptingTab = tabManager[webView] {
            promptingTab.queueJavascriptAlertPrompt(textInputAlert)
            completionHandler(nil)
        }
    }

    func webViewDidClose(_ webView: WKWebView) {
        if let tab = tabManager[webView] {
            // Need to wait here in case we're waiting for a pending `window.open()`.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) {
                self.tabManager.removeTab(tab)
            }
        }
    }

    func webView(
        _ webView: WKWebView,
        contextMenuConfigurationForElement elementInfo: WKContextMenuElementInfo,
        completionHandler: @escaping (UIContextMenuConfiguration?) -> Void
    ) {
        completionHandler(UIContextMenuConfiguration(
            identifier: nil,
            previewProvider: {
                guard let url = elementInfo.linkURL,
                      self.profile.prefs.boolForKey(PrefsKeys.ContextMenuShowLinkPreviews) ?? true
                else { return nil }

                let previewViewController = UIViewController()
                previewViewController.view.isUserInteractionEnabled = false
                let clonedWebView = WKWebView(frame: webView.frame, configuration: webView.configuration)

                previewViewController.view.addSubview(clonedWebView)
                clonedWebView.snp.makeConstraints { make in
                    make.edges.equalTo(previewViewController.view)
                }

                clonedWebView.load(URLRequest(url: url))

                return previewViewController
            }, actionProvider: { [self] (suggested) -> UIMenu? in
                guard let url = elementInfo.linkURL,
                      let currentTab = self.tabManager.selectedTab,
                      let contextHelper = currentTab.getContentScript(name: ContextMenuHelper.name()) as? ContextMenuHelper,
                      let elements = contextHelper.elements
                else { return nil }

                let isPrivate = currentTab.isPrivate
                var setAddTabAdSearchParam = false
                let addTab = { (rURL: URL, isPrivate: Bool) in
                    let adUrl = rURL.absoluteString
                    if currentTab == self.tabManager.selectedTab,
                       !currentTab.adsTelemetryUrlList.isEmpty,
                       currentTab.adsTelemetryUrlList.contains(adUrl),
                       !currentTab.adsProviderName.isEmpty {
                        AdsTelemetryHelper.trackAdsClickedOnPage(providerName: currentTab.adsProviderName)
                        currentTab.adsTelemetryUrlList.removeAll()
                        currentTab.adsTelemetryRedirectUrlList.removeAll()
                        currentTab.adsProviderName = ""

                        // Set the tab search param from current tab considering we need the values in order to cope with ad redirects
                    } else if !currentTab.adsProviderName.isEmpty {
                        setAddTabAdSearchParam = true
                    }

                    let tab = self.tabManager.addTab(URLRequest(url: rURL as URL), afterTab: currentTab, isPrivate: isPrivate)

                    if setAddTabAdSearchParam {
                        tab.adsProviderName = currentTab.adsProviderName
                        tab.adsTelemetryUrlList = currentTab.adsTelemetryUrlList
                        tab.adsTelemetryRedirectUrlList = currentTab.adsTelemetryRedirectUrlList
                    }

                    // Record Observation for Search Term Groups
                    let searchTerm = currentTab.metadataManager?.tabGroupData.tabAssociatedSearchTerm ?? ""
                    let searchUrl = currentTab.metadataManager?.tabGroupData.tabAssociatedSearchUrl ?? ""
                    if !searchTerm.isEmpty, !searchUrl.isEmpty {
                        let searchData = TabGroupData(searchTerm: searchTerm,
                                                      searchUrl: searchUrl,
                                                      nextReferralUrl: tab.url?.absoluteString ?? "")
                        tab.metadataManager?.updateTimerAndObserving(state: .openInNewTab, searchData: searchData, isPrivate: tab.isPrivate)
                    }

                    guard !self.topTabsVisible else { return }
                    var toastLabelText: String

                    if isPrivate {
                        toastLabelText = .ContextMenuButtonToastNewPrivateTabOpenedLabelText
                    } else {
                        toastLabelText = .ContextMenuButtonToastNewTabOpenedLabelText
                    }
                    // We're not showing the top tabs; show a toast to quick switch to the fresh new tab.
                    let viewModel = ButtonToastViewModel(labelText: toastLabelText,
                                                         buttonText: .ContextMenuButtonToastNewTabOpenedButtonText)
                    let toast = ButtonToast(viewModel: viewModel,
                                            theme: self.themeManager.currentTheme,
                                            completion: { buttonPressed in
                        if buttonPressed {
                            self.tabManager.selectTab(tab)
                        }
                    })
                    self.show(toast: toast)
                }

                let getImageData = { (_ url: URL, success: @escaping (Data) -> Void) in
                    makeURLSession(
                        userAgent: UserAgent.fxaUserAgent,
                        configuration: URLSessionConfiguration.default).dataTask(with: url) { (data, response, error) in
                            if validatedHTTPResponse(response, statusCode: 200..<300) != nil,
                               let data = data {
                                success(data)
                            }
                        }.resume()
                }

                var actions = [UIAction]()

                if !isPrivate {
                    actions.append(
                        UIAction(
                            title: .ContextMenuOpenInNewTab,
                            image: UIImage.templateImageNamed("menu-NewTab"),
                            identifier: UIAction.Identifier(rawValue: "linkContextMenu.openInNewTab")
                        ) { _ in
                            addTab(url, false)
                        })
                }

                actions.append(
                    UIAction(
                        title: .ContextMenuOpenInNewPrivateTab,
                        image: UIImage.templateImageNamed("menu-NewPrivateTab"),
                        identifier: UIAction.Identifier("linkContextMenu.openInNewPrivateTab")
                    ) { _ in
                        addTab(url, true)
                    })

                let addBookmarkAction = UIAction(
                    title: .ContextMenuBookmarkLink,
                    image: UIImage.templateImageNamed(ImageIdentifiers.addToBookmark),
                    identifier: UIAction.Identifier("linkContextMenu.bookmarkLink")
                ) { _ in
                    self.addBookmark(url: url.absoluteString, title: elements.title)
                    TelemetryWrapper.recordEvent(category: .action,
                                                 method: .add,
                                                 object: .bookmark,
                                                 value: .contextMenu)
                }

                let removeAction = UIAction(
                    title: .RemoveBookmarkContextMenuTitle,
                    image: UIImage.templateImageNamed(ImageIdentifiers.actionRemoveBookmark),
                    identifier: UIAction.Identifier("linkContextMenu.removeBookmarkLink")
                ) { _ in
                    self.removeBookmark(url: url.absoluteString)
                    TelemetryWrapper.recordEvent(category: .action,
                                                 method: .delete,
                                                 object: .bookmark,
                                                 value: .contextMenu)
                }

                let isBookmarkedSite = profile.places.isBookmarked(url: url.absoluteString).value.successValue ?? false
                actions.append(isBookmarkedSite ? removeAction : addBookmarkAction)

                actions.append(UIAction(title: .ContextMenuDownloadLink, image: UIImage.templateImageNamed(ImageIdentifiers.downloads), identifier: UIAction.Identifier("linkContextMenu.download")) { _ in
                    // This checks if download is a blob, if yes, begin blob download process
                    if !DownloadContentScript.requestBlobDownload(url: url, tab: currentTab) {
                        // if not a blob, set pendingDownloadWebView and load the request in
                        // the webview, which will trigger the WKWebView navigationResponse
                        // delegate function and eventually downloadHelper.open()
                        self.pendingDownloadWebView = currentTab.webView
                        let request = URLRequest(url: url)
                        currentTab.webView?.load(request)
                    }
                })

                actions.append(UIAction(
                    title: .ContextMenuCopyLink,
                    image: UIImage.templateImageNamed(ImageIdentifiers.copyLink),
                    identifier: UIAction.Identifier("linkContextMenu.copyLink")
                ) { _ in
                    UIPasteboard.general.url = url
                })

                actions.append(UIAction(title: .ContextMenuShareLink, image: UIImage.templateImageNamed(ImageIdentifiers.share), identifier: UIAction.Identifier("linkContextMenu.share")) { _ in
                    guard let tab = self.tabManager[webView],
                          let helper = tab.getContentScript(name: ContextMenuHelper.name()) as? ContextMenuHelper
                    else { return }

                    // This is only used on ipad for positioning the popover. On iPhone it is an action sheet.
                    let point = webView.convert(helper.touchPoint, to: self.view)
                    self.presentActivityViewController(url as URL, sourceView: self.view, sourceRect: CGRect(origin: point, size: CGSize(width: 10, height: 10)), arrowDirection: .unknown)
                })

                if let url = elements.image {
                    actions.append(UIAction(title: .ContextMenuSaveImage, identifier: UIAction.Identifier("linkContextMenu.saveImage")) { _ in
                        getImageData(url) { data in
                            guard let image = UIImage(data: data) else { return }
                            self.writeToPhotoAlbum(image: image)
                        }
                    })

                    actions.append(UIAction(title: .ContextMenuCopyImage, identifier: UIAction.Identifier("linkContextMenu.copyImage")) { _ in
                        // put the actual image on the clipboard
                        // do this asynchronously just in case we're in a low bandwidth situation
                        let pasteboard = UIPasteboard.general
                        pasteboard.url = url as URL
                        let changeCount = pasteboard.changeCount
                        let application = UIApplication.shared
                        var taskId: UIBackgroundTaskIdentifier = UIBackgroundTaskIdentifier(rawValue: 0)
                        taskId = application.beginBackgroundTask(expirationHandler: {
                            application.endBackgroundTask(taskId)
                        })

                        makeURLSession(userAgent: UserAgent.fxaUserAgent, configuration: URLSessionConfiguration.default).dataTask(with: url) { (data, response, error) in
                            guard validatedHTTPResponse(response, statusCode: 200..<300) != nil else {
                                application.endBackgroundTask(taskId)
                                return
                            }

                            // Only set the image onto the pasteboard if the pasteboard hasn't changed since
                            // fetching the image; otherwise, in low-bandwidth situations,
                            // we might be overwriting something that the user has subsequently added.
                            if changeCount == pasteboard.changeCount, let imageData = data, error == nil {
                                pasteboard.addImageWithData(imageData, forURL: url)
                            }

                            application.endBackgroundTask(taskId)
                        }.resume()
                    })

                    actions.append(UIAction(title: .ContextMenuCopyImageLink, identifier: UIAction.Identifier("linkContextMenu.copyImageLink")) { _ in
                        UIPasteboard.general.url = url as URL
                    })
                }

                return UIMenu(title: url.absoluteString, children: actions)
            }))
    }

    @available(iOS 15, *)
    func webView(_ webView: WKWebView,
                 requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo,
                 type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        // If the tab isn't the selected one, do not show the media capture prompt
        guard tabManager.selectedTab?.webView == webView else {
            decisionHandler(.deny)
            return
        }

        decisionHandler(.prompt)
    }

    func writeToPhotoAlbum(image: UIImage) {
        UIImageWriteToSavedPhotosAlbum(image, self, #selector(saveError), nil)
    }

    @objc func saveError(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeRawPointer) {
        guard error != nil else { return }
        DispatchQueue.main.async {
            let accessDenied = UIAlertController(title: .PhotoLibraryFirefoxWouldLikeAccessTitle, message: .PhotoLibraryFirefoxWouldLikeAccessMessage, preferredStyle: .alert)
            let dismissAction = UIAlertAction(title: .CancelString, style: .default, handler: nil)
            accessDenied.addAction(dismissAction)
            let settingsAction = UIAlertAction(title: .OpenSettingsString, style: .default ) { _ in
                UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!, options: [:])
            }
            accessDenied.addAction(settingsAction)
            self.present(accessDenied, animated: true, completion: nil)
        }
    }
}

// MARK: - WKNavigationDelegate
extension BrowserViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        guard let tab = tabManager[webView] else { return }

        if !tab.adsTelemetryUrlList.isEmpty,
           !tab.adsProviderName.isEmpty,
           let webUrl = webView.url {
            tab.adsTelemetryRedirectUrlList.append(webUrl)
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        if tabManager.selectedTab?.webView !== webView {
            return
        }

        updateFindInPageVisibility(visible: false)

        // If we are going to navigate to a new page, hide the reader mode button. Unless we
        // are going to a about:reader page. Then we keep it on screen: it will change status
        // (orange color) as soon as the page has loaded.
        if let url = webView.url {
            if !url.isReaderModeURL {
                urlBar.updateReaderModeState(ReaderModeState.unavailable, hideReloadButton: shouldUseiPadSetup())
                hideReaderModeBar(animated: false)
            }
        }
    }

    // This is the place where we decide what to do with a new navigation action. There are a number of special schemes
    // and http(s) urls that need to be handled in a different way. All the logic for that is inside this delegate
    // method.
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url,
              let tab = tabManager[webView]
        else {
            decisionHandler(.cancel)
            return
        }

        if tab == tabManager.selectedTab,
           navigationAction.navigationType == .linkActivated,
           !tab.adsTelemetryUrlList.isEmpty {
            let adUrl = url.absoluteString
            if tab.adsTelemetryUrlList.contains(adUrl) {
                if !tab.adsProviderName.isEmpty { AdsTelemetryHelper.trackAdsClickedOnPage(providerName: tab.adsProviderName) }
                tab.adsTelemetryUrlList.removeAll()
                tab.adsTelemetryRedirectUrlList.removeAll()
                tab.adsProviderName = ""
            }
        }

        if InternalURL.isValid(url: url) {
            if navigationAction.navigationType != .backForward, navigationAction.isInternalUnprivileged {
                logger.log("Denying unprivileged request: \(navigationAction.request)",
                           level: .warning,
                           category: .webview)
                decisionHandler(.cancel)
                return
            }

            decisionHandler(.allow)
            return
        }

        // First special case are some schemes that are about Calling. We prompt the user to confirm this action. This
        // gives us the exact same behaviour as Safari.
        if ["sms", "tel", "facetime", "facetime-audio"].contains(url.scheme) {
            if url.scheme == "sms" { // All the other types show a native prompt
                showSnackbar(forExternalUrl: url, tab: tab) { isOk in
                    guard isOk else { return }
                    UIApplication.shared.open(url, options: [:])
                }
            } else {
                UIApplication.shared.open(url, options: [:])
            }

            decisionHandler(.cancel)
            return
        }

        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }

        // Disabled due to https://bugzilla.mozilla.org/show_bug.cgi?id=1588928
        //        if url.scheme == "javascript", navigationAction.request.isPrivileged {
        //            decisionHandler(.cancel)
        //            if let javaScriptString = url.absoluteString.replaceFirstOccurrence(of: "javascript:", with: "").removingPercentEncoding {
        //                webView.evaluateJavaScript(javaScriptString)
        //            }
        //            return
        //        }

        if isStoreURL(url) {
            decisionHandler(.cancel)

            // Make sure to wait longer than delaySelectingNewPopupTab to ensure selectedTab is correct
            DispatchQueue.main.asyncAfter(deadline: .now() + tabManager.delaySelectingNewPopupTab + 0.1) {
                // Show only if no other snack bar
                guard let tab = self.tabManager.selectedTab, tab.bars.isEmpty else { return }
                TimerSnackBar.showAppStoreConfirmationBar(forTab: tab, appStoreURL: url) { _ in
                    // If a new window was opened for this URL (it will have no history), close it.
                    if tab.historyList.isEmpty {
                        self.tabManager.removeTab(tab)
                    }
                }
            }
            return
        }

        // Handles custom mailto URL schemes.
        if url.scheme == "mailto" {
            showSnackbar(forExternalUrl: url, tab: tab) { isOk in
                guard isOk else { return }

                if let mailToMetadata = url.mailToMetadata(), let mailScheme = self.profile.prefs.stringForKey(PrefsKeys.KeyMailToOption), mailScheme != "mailto" {
                    self.mailtoLinkHandler.launchMailClientForScheme(mailScheme, metadata: mailToMetadata, defaultMailtoURL: url)
                } else {
                    UIApplication.shared.open(url, options: [:])
                }
            }

            decisionHandler(.cancel)
            return
        }

        // Handle Universal link for Firefox wallpaper setting
        if isFirefoxUniversalWallpaperSetting(url) {
            showWallpaperSettings()
            decisionHandler(.cancel)
            return
        }

        let navigationHandler = WebViewNavigationHandlerImplementation(decisionHandler: decisionHandler)
        if navigationHandler.shouldFilterDataScheme(url: url) {
            navigationHandler.filterDataScheme(url: url, navigationAction: navigationAction)
            return
        }

        // Handle keyboard shortcuts on link presses from webpage navigation (ex: Cmd + Tap on Link)
        if navigationAction.navigationType == .linkActivated, navigateLinkShortcutIfNeeded(url: url) {
            decisionHandler(.cancel)
            return
        }

        // This is the normal case, opening a http or https url, which we handle by loading them in this WKWebView. We
        // always allow this. Additionally, data URIs are also handled just like normal web pages.

        if ["http", "https", "blob", "file"].contains(url.scheme) {
            if navigationAction.targetFrame?.isMainFrame ?? false {
                tab.changedUserAgent = Tab.ChangeUserAgent.contains(url: url)
            }

            pendingRequests[url.absoluteString] = navigationAction.request

            if tab.changedUserAgent {
                let platformSpecificUserAgent = UserAgent.oppositeUserAgent(domain: url.baseDomain ?? "")
                webView.customUserAgent = platformSpecificUserAgent
            } else {
                webView.customUserAgent = UserAgent.getUserAgent(domain: url.baseDomain ?? "")
            }

            decisionHandler(.allow)
            return
        }

        if !(url.scheme?.contains("firefox") ?? true) {
            showSnackbar(forExternalUrl: url, tab: tab) { isOk in
                guard isOk else { return }
                UIApplication.shared.open(url, options: [:]) { openedURL in
                    // Do not show error message for JS navigated links or redirect as it's not the result of a user action.
                    if !openedURL, navigationAction.navigationType == .linkActivated {
                        let alert = UIAlertController(title: .UnableToOpenURLErrorTitle, message: .UnableToOpenURLError, preferredStyle: .alert)
                        alert.addAction(UIAlertAction(title: .OKString, style: .default, handler: nil))
                        self.present(alert, animated: true, completion: nil)
                    }
                }
            }
        }

        decisionHandler(.cancel)
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationResponse: WKNavigationResponse,
        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void
    ) {
        let response = navigationResponse.response
        let responseURL = response.url

        var request: URLRequest?
        if let url = responseURL {
            request = pendingRequests.removeValue(forKey: url.absoluteString)
        }

        // We can only show this content in the web view if this web view is not pending
        // download via the context menu.
        let canShowInWebView = navigationResponse.canShowMIMEType && (webView != pendingDownloadWebView)
        let forceDownload = webView == pendingDownloadWebView
        let cookieStore = webView.configuration.websiteDataStore.httpCookieStore

        if OpenPassBookHelper.shouldOpenWithPassBook(response: response,
                                                     forceDownload: forceDownload) {
            passBookHelper = OpenPassBookHelper(response: response,
                                                cookieStore: cookieStore,
                                                presenter: self)
            // Open our helper and nullifies the helper when done with it
            passBookHelper?.open {
                self.passBookHelper = nil
            }

            // Cancel this response from the webview.
            decisionHandler(.cancel)
            return
        }

        if OpenQLPreviewHelper.shouldOpenPreviewHelper(response: response,
                                                       forceDownload: forceDownload),
           let tab = tabManager[webView],
           let request = request {
            let previewHelper = OpenQLPreviewHelper(presenter: self)
            // Certain files are too large to download before the preview presents,
            // block and use a temporary document instead
            tab.temporaryDocument = TemporaryDocument(preflightResponse: response,
                                                      request: request)
            let group = DispatchGroup()
            var url: URL?
            group.enter()
            tab.temporaryDocument?.getURL(completionHandler: { docURL in
                url = docURL
                group.leave()
            })
            _ = group.wait(timeout: .distantFuture)

            if previewHelper.canOpen(url: url) {
                // Open our helper and cancel this response from the webview.
                previewHelper.open()
                decisionHandler(.cancel)
                return
            } else {
                tab.temporaryDocument = nil
                // We don't have a temporary document, fallthrough
            }
        }

        // Check if this response should be downloaded.
        if let downloadHelper = DownloadHelper(request: request,
                                               response: response,
                                               cookieStore: cookieStore,
                                               canShowInWebView: canShowInWebView,
                                               forceDownload: forceDownload) {
            // Clear the pending download web view so that subsequent navigations from the same
            // web view don't invoke another download.
            pendingDownloadWebView = nil

            let downloadAction: (HTTPDownload) -> Void = { [weak self] download in
                self?.downloadQueue.enqueue(download)
            }

            // Open our helper and cancel this response from the webview.
            if let downloadViewModel = downloadHelper.downloadViewModel(okAction: downloadAction) {
                presentSheetWith(viewModel: downloadViewModel, on: self, from: urlBar)
            }
            decisionHandler(.cancel)
            return
        }

        // If the content type is not HTML, create a temporary document so it can be downloaded and
        // shared to external applications later. Otherwise, clear the old temporary document.
        // NOTE: This should only happen if the request/response came from the main frame, otherwise
        // we may end up overriding the "Share Page With..." action to share a temp file that is not
        // representative of the contents of the web view.
        if navigationResponse.isForMainFrame, let tab = tabManager[webView] {
            if response.mimeType != MIMEType.HTML, let request = request {
                tab.temporaryDocument = TemporaryDocument(preflightResponse: response, request: request)
            } else {
                tab.temporaryDocument = nil
            }

            tab.mimeType = response.mimeType
        }

        // If none of our helpers are responsible for handling this response,
        // just let the webview handle it as normal.
        decisionHandler(.allow)
    }

    /// Invoked when an error occurs while starting to load data for the main frame.
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        // Ignore the "Frame load interrupted" error that is triggered when we cancel a request
        // to open an external application and hand it over to UIApplication.openURL(). The result
        // will be that we switch to the external app, for example the app store, while keeping the
        // original web page in the tab instead of replacing it with an error page.
        let error = error as NSError
        if error.domain == "WebKitErrorDomain" && error.code == 102 {
            return
        }

        guard !checkIfWebContentProcessHasCrashed(webView, error: error as NSError) else { return }

        if error.code == Int(CFNetworkErrors.cfurlErrorCancelled.rawValue) {
            if let tab = tabManager[webView], tab === tabManager.selectedTab {
                urlBar.currentURL = tab.url?.displayURL
            }
            return
        }

        if let url = error.userInfo[NSURLErrorFailingURLErrorKey] as? URL {
            ErrorPageHelper(certStore: profile.certStore).loadPage(error, forUrl: url, inWebView: webView)
        }
    }

    func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod != NSURLAuthenticationMethodServerTrust else {
            handleServerTrust(challenge: challenge, completionHandler: completionHandler)
            return
        }

        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPBasic ||
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodHTTPDigest ||
              challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodNTLM,
              let tab = tabManager[webView]
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        // If this is a request to our local web server, use our private credentials.
        if challenge.protectionSpace.host == "localhost" &&
            challenge.protectionSpace.port == Int(WebServer.sharedInstance.server.port) {
            completionHandler(.useCredential, WebServer.sharedInstance.credentials)
            return
        }

        // The challenge may come from a background tab, so ensure it's the one visible.
        tabManager.selectTab(tab)

        let loginsHelper = tab.getContentScript(name: LoginsHelper.name()) as? LoginsHelper
        Authenticator.handleAuthRequest(self, challenge: challenge, loginsHelper: loginsHelper).uponQueue(.main) { res in
            if let credentials = res.successValue {
                completionHandler(.useCredential, credentials.credentials)
            } else {
                completionHandler(.rejectProtectionSpace, nil)
            }
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tabManager[webView],
              let metadataManager = tab.metadataManager
        else { return }

        searchTelemetry?.trackTabAndTopSiteSAP(tab, webView: webView)
        tab.url = webView.url

        // Only update search term data with valid search term data
        if metadataManager.shouldUpdateSearchTermData(webViewUrl: webView.url?.absoluteString) {
            if !tab.adsTelemetryRedirectUrlList.isEmpty,
               !tab.adsProviderName.isEmpty,
               !tab.adsTelemetryUrlList.isEmpty,
               !tab.adsProviderName.isEmpty,
               let startingRedirectHost = tab.startingSearchUrlWithAds?.host,
               let lastRedirectHost = tab.adsTelemetryRedirectUrlList.last?.host,
               lastRedirectHost != startingRedirectHost {
                AdsTelemetryHelper.trackAdsClickedOnPage(providerName: tab.adsProviderName)
                tab.adsTelemetryUrlList.removeAll()
                tab.adsTelemetryRedirectUrlList.removeAll()
                tab.adsProviderName = ""
            }

            updateObservationReferral(metadataManager: metadataManager, url: webView.url?.absoluteString, isPrivate: tab.isPrivate)
        }

        // When tab url changes after web content starts loading on the page
        // We notify the content blocker change so that content blocker status can be correctly shown on beside the URL bar
        tab.contentBlocker?.notifyContentBlockingChanged()
        self.scrollController.resetZoomState()

        if tabManager.selectedTab === tab {
            updateUIForReaderHomeStateForTab(tab, focusUrlBar: true)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabManager[webView],
           let metadataManager = tab.metadataManager {
            navigateInTab(tab: tab, to: navigation, webViewStatus: .finishedNavigation)

            // Only update search term data with valid search term data
            if metadataManager.shouldUpdateSearchTermData(webViewUrl: webView.url?.absoluteString) {
                updateObservationReferral(metadataManager: metadataManager, url: webView.url?.absoluteString, isPrivate: tab.isPrivate)
            } else if !tab.isFxHomeTab {
                let searchData = TabGroupData(searchTerm: metadataManager.tabGroupData.tabAssociatedSearchTerm,
                                              searchUrl: webView.url?.absoluteString ?? "",
                                              nextReferralUrl: "")
                metadataManager.updateTimerAndObserving(state: .openURLOnly,
                                                        searchData: searchData,
                                                        tabTitle: webView.title,
                                                        isPrivate: tab.isPrivate)
            }

            // If this tab had previously crashed, wait 5 seconds before resetting
            // the consecutive crash counter. This allows a successful webpage load
            // without a crash to reset the consecutive crash counter in the event
            // that the tab begins crashing again in the future.
            if tab.consecutiveCrashes > 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(5)) {
                    if tab.consecutiveCrashes > 0 {
                        tab.consecutiveCrashes = 0
                    }
                }
            }
        }
    }
}

// MARK: - Private
private extension BrowserViewController {
    // Handle Universal link for Firefox wallpaper setting
    func isFirefoxUniversalWallpaperSetting(_ url: URL) -> Bool {
        guard let scheme = url.scheme,
              [URL.mozPublicScheme, URL.mozInternalScheme].contains(scheme)
        else { return false }

        let deeplinkUrl = "\(scheme)://deep-link?url=/settings/wallpaper"
        if url.absoluteString == deeplinkUrl { return true }

        return false
    }

    // Recognize an Apple Maps URL. This will trigger the native app. But only if a search query is present. Otherwise
    // it could just be a visit to a regular page on maps.apple.com.
    func isAppleMapsURL(_ url: URL) -> Bool {
        if url.scheme == "http" || url.scheme == "https" {
            if url.host == "maps.apple.com" && url.query != nil {
                return true
            }
        }
        return false
    }

    // Recognize a iTunes Store URL. These all trigger the native apps. Note that appstore.com and phobos.apple.com
    // used to be in this list. I have removed them because they now redirect to itunes.apple.com. If we special case
    // them then iOS will actually first open Safari, which then redirects to the app store. This works but it will
    // leave a 'Back to Safari' button in the status bar, which we do not want.
    func isStoreURL(_ url: URL) -> Bool {
        if url.scheme == "http" || url.scheme == "https" || url.scheme == "itms-apps" {
            if url.host == "itunes.apple.com" {
                return true
            }
        }
        return false
    }

    // Use for sms and mailto links, which do not show a confirmation before opening.
    func showSnackbar(forExternalUrl url: URL, tab: Tab, completion: @escaping (Bool) -> Void) {
        let snackBar = TimerSnackBar(text: .ExternalLinkGenericConfirmation + "\n\(url.absoluteString)", img: nil)
        let ok = SnackButton(title: .OKString, accessibilityIdentifier: "AppOpenExternal.button.ok") { bar in
            tab.removeSnackbar(bar)
            completion(true)
        }
        let cancel = SnackButton(title: .CancelString, accessibilityIdentifier: "AppOpenExternal.button.cancel") { bar in
            tab.removeSnackbar(bar)
            completion(false)
        }
        snackBar.addButton(ok)
        snackBar.addButton(cancel)
        tab.addSnackbar(snackBar)
    }

    func shouldRequestBeOpenedAsPopup(_ request: URLRequest) -> Bool {
        // Treat `window.open("")` the same as `window.open("about:blank")`.
        if request.url?.absoluteString.isEmpty ?? false {
            return true
        }

        if let scheme = request.url?.scheme?.lowercased(), schemesAllowedToBeOpenedAsPopups.contains(scheme) {
            return true
        }

        return false
    }

    func shouldDisplayJSAlertForWebView(_ webView: WKWebView) -> Bool {
        // Only display a JS Alert if we are selected and there isn't anything being shown
        return ((tabManager.selectedTab == nil ? false : tabManager.selectedTab!.webView == webView))
            && (self.presentedViewController == nil)
    }

     func checkIfWebContentProcessHasCrashed(_ webView: WKWebView, error: NSError) -> Bool {
        if error.code == WKError.webContentProcessTerminated.rawValue && error.domain == "WebKitErrorDomain" {
            logger.log("WebContent process has crashed. Trying to reload to restart it.",
                       level: .warning,
                       category: .webview)
            webView.reload()
            return true
        }

        return false
    }

    func handleServerTrust(challenge: URLAuthenticationChallenge,
                           completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        // If this is a certificate challenge, see if the certificate has previously been
        // accepted by the user.
        let origin = "\(challenge.protectionSpace.host):\(challenge.protectionSpace.port)"

        guard let trust = challenge.protectionSpace.serverTrust,
              let cert = SecTrustGetCertificateAtIndex(trust, 0),
              profile.certStore.containsCertificate(cert, forOrigin: origin)
        else {
            completionHandler(.performDefaultHandling, nil)
            return
        }

        completionHandler(.useCredential, URLCredential(trust: trust))
    }

    func updateObservationReferral(metadataManager: TabMetadataManager, url: String?, isPrivate: Bool) {
        let searchData = TabGroupData(searchTerm: metadataManager.tabGroupData.tabAssociatedSearchTerm,
                                      searchUrl: metadataManager.tabGroupData.tabAssociatedSearchUrl,
                                      nextReferralUrl: url ?? "")
        metadataManager.updateTimerAndObserving(
            state: .tabNavigatedToDifferentUrl,
            searchData: searchData,
            isPrivate: isPrivate)
    }
}

extension WKNavigationAction {
    /// Allow local requests only if the request is privileged.
    var isInternalUnprivileged: Bool {
        guard let url = request.url else { return true }

        if let url = InternalURL(url) {
            return !url.isAuthorized
        } else {
            return false
        }
    }
}
