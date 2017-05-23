//
//  TaskDelegate.swift
//
//  Copyright (c) 2014-2016 Alamofire Software Foundation (http://alamofire.org/)
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

import Foundation

/// The task delegate is responsible for handling all delegate callbacks for the underlying task as well as
/// executing all operations attached to the serial operation queue upon task completion.
open class TaskDelegate: NSObject {

    // MARK: Properties

    /// The serial operation queue used to execute all operations after the task completes.
    // 串行队列
    open let queue: OperationQueue

    /// The data returned by the server.
    // 服务器返回的数据
    public var data: Data? { return nil }

    /// The error generated throughout the lifecyle of the task.
    public var error: Error?

    var task: URLSessionTask? {
        didSet { reset() }
    }

    // CFAbsoluteTime --> CFTimeInterval --> Double
    // 时间
    var initialResponseTime: CFAbsoluteTime?
    // 凭证
    var credential: URLCredential?
    // 统计task的一些相关信息
    var metrics: AnyObject? // URLSessionTaskMetrics

    // MARK: Lifecycle

    init(task: URLSessionTask?) {
        self.task = task

        // 创建一个函数,并且立即调用
        self.queue = {
            // 操作队列
            let operationQueue = OperationQueue()

            operationQueue.maxConcurrentOperationCount = 1
            // 保证队列中的operation都是暂停状态
            operationQueue.isSuspended = true
            operationQueue.qualityOfService = .utility

            return operationQueue
        }()
    }

    func reset() {
        error = nil
        initialResponseTime = nil
    }

    // MARK: URLSessionTaskDelegate

    // task代理回调,闭包
    // 这是URLSessionTaskDelegate的方法
    var taskWillPerformHTTPRedirection: ((URLSession, URLSessionTask, HTTPURLResponse, URLRequest) -> URLRequest?)?
    var taskDidReceiveChallenge: ((URLSession, URLSessionTask, URLAuthenticationChallenge) -> (URLSession.AuthChallengeDisposition, URLCredential?))?
    var taskNeedNewBodyStream: ((URLSession, URLSessionTask) -> InputStream?)?
    var taskDidCompleteWithError: ((URLSession, URLSessionTask, Error?) -> Void)?

    // 重定向, 返回重定向的URLRequest, 如果给重定向赋值了就返回代理函数的返回值(即如果taskWillPerformHTTPRedirection不为空,就调用redirectRequest = taskWillPerformHTTPRedirection(session, task, response, request)方法), 如果没有赋值就返回原始的URLRequest
    @objc(URLSession:task:willPerformHTTPRedirection:newRequest:completionHandler:)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void)
    {
        var redirectRequest: URLRequest? = request

        // 可选绑定
        if let taskWillPerformHTTPRedirection = taskWillPerformHTTPRedirection {
            redirectRequest = taskWillPerformHTTPRedirection(session, task, response, request)
        }

        completionHandler(redirectRequest)
    }

    // 接收到挑战, 处理验证相关的事务
    @objc(URLSession:task:didReceiveChallenge:completionHandler:)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void)
    {
        // 枚举类型, 授权配置
        var disposition: URLSession.AuthChallengeDisposition = .performDefaultHandling
        var credential: URLCredential?

        // 如果服务器需要验证客户端,只需要给taskDidReceiveChallenge赋值即可
        if let taskDidReceiveChallenge = taskDidReceiveChallenge {
            (disposition, credential) = taskDidReceiveChallenge(session, task, challenge)
        } else if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            let host = challenge.protectionSpace.host

            if
                let serverTrustPolicy = session.serverTrustPolicyManager?.serverTrustPolicy(forHost: host),
                let serverTrust = challenge.protectionSpace.serverTrust
            {
                if serverTrustPolicy.evaluate(serverTrust, forHost: host) {
                    disposition = .useCredential
                    credential = URLCredential(trust: serverTrust)
                } else {
                    disposition = .cancelAuthenticationChallenge
                }
            }
        } else {
            if challenge.previousFailureCount > 0 {
                disposition = .rejectProtectionSpace
            } else {
                credential = self.credential ?? session.configuration.urlCredentialStorage?.defaultCredential(for: challenge.protectionSpace)

                if credential != nil {
                    disposition = .useCredential
                }
            }
        }

        completionHandler(disposition, credential)
    }

    
    @objc(URLSession:task:needNewBodyStream:)
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        needNewBodyStream completionHandler: @escaping (InputStream?) -> Void)
    {
        var bodyStream: InputStream?

        if let taskNeedNewBodyStream = taskNeedNewBodyStream {
            bodyStream = taskNeedNewBodyStream(session, task)
        }

        completionHandler(bodyStream)
    }

    
    @objc(URLSession:task:didCompleteWithError:)
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let taskDidCompleteWithError = taskDidCompleteWithError {
            taskDidCompleteWithError(session, task, error)
        } else {
            if let error = error {
                if self.error == nil { self.error = error }

                if
                    let downloadDelegate = self as? DownloadTaskDelegate,
                    let resumeData = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
                {
                    downloadDelegate.resumeData = resumeData
                }
            }

            queue.isSuspended = false
        }
    }
}

// MARK: -

class DataTaskDelegate: TaskDelegate, URLSessionDataDelegate {

    // MARK: Properties

    var dataTask: URLSessionDataTask { return task as! URLSessionDataTask }

    // 如果dataStream赋值了,那么data就为空
    override var data: Data? {
        if dataStream != nil {
            return nil
        } else {
            return mutableData
        }
    }

    var progress: Progress
    // 这是一个元组,不是函数, progresssHandler执行的队列
    var progressHandler: (closure: Request.ProgressHandler, queue: DispatchQueue)?

    // 自定义的数据处理函数
    var dataStream: ((_ data: Data) -> Void)?

    private var totalBytesReceived: Int64 = 0
    // 数据容器
    private var mutableData: Data

    private var expectedContentLength: Int64?

    // MARK: Lifecycle

    override init(task: URLSessionTask?) {
        mutableData = Data()
        progress = Progress(totalUnitCount: 0)

        super.init(task: task)
    }

    override func reset() {
        super.reset()

        progress = Progress(totalUnitCount: 0)
        totalBytesReceived = 0
        mutableData = Data()
        expectedContentLength = nil
    }

    // MARK: URLSessionDataDelegate

    var dataTaskDidReceiveResponse: ((URLSession, URLSessionDataTask, URLResponse) -> URLSession.ResponseDisposition)?
    var dataTaskDidBecomeDownloadTask: ((URLSession, URLSessionDataTask, URLSessionDownloadTask) -> Void)?
    var dataTaskDidReceiveData: ((URLSession, URLSessionDataTask, Data) -> Void)?
    var dataTaskWillCacheResponse: ((URLSession, URLSessionDataTask, CachedURLResponse) -> CachedURLResponse?)?

    // 接收到服务端的响应, 接收到和数据相关的一些参数
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void)
    {
        var disposition: URLSession.ResponseDisposition = .allow

        expectedContentLength = response.expectedContentLength

        // 如果对dataTaskDidReceiveResponse赋值了,就调用
        if let dataTaskDidReceiveResponse = dataTaskDidReceiveResponse {
            disposition = dataTaskDidReceiveResponse(session, dataTask, response)
        }

        // 控制是否要接收数据(枚举类型,cancel取消, allow允许, becomeDownload将请求变为下载, becomeStream变为stream)
        completionHandler(disposition)
    }

    // dataTask转为downloadTask,可以通过设置dataTaskDidReceiveResponse为.becomeDownload,将dataTask转为downloadTask
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didBecome downloadTask: URLSessionDownloadTask)
    {
        dataTaskDidBecomeDownloadTask?(session, dataTask, downloadTask)
    }

    // 接收到服务器数据
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        // 消耗时长
        if initialResponseTime == nil { initialResponseTime = CFAbsoluteTimeGetCurrent() }

        if let dataTaskDidReceiveData = dataTaskDidReceiveData {
            dataTaskDidReceiveData(session, dataTask, data)
        } else {
            if let dataStream = dataStream {
                dataStream(data)
            } else {
                mutableData.append(data)
            }

            let bytesReceived = Int64(data.count)
            totalBytesReceived += bytesReceived
            let totalBytesExpected = dataTask.response?.expectedContentLength ?? NSURLSessionTransferSizeUnknown

            progress.totalUnitCount = totalBytesExpected
            progress.completedUnitCount = totalBytesReceived

            if let progressHandler = progressHandler {
                progressHandler.queue.async { progressHandler.closure(self.progress) }
            }
        }
    }

    // 是否缓存响应
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        willCacheResponse proposedResponse: CachedURLResponse,
        completionHandler: @escaping (CachedURLResponse?) -> Void)
    {
        var cachedResponse: CachedURLResponse? = proposedResponse

        if let dataTaskWillCacheResponse = dataTaskWillCacheResponse {
            cachedResponse = dataTaskWillCacheResponse(session, dataTask, proposedResponse)
        }

        completionHandler(cachedResponse)
    }
}

// MARK: -

class DownloadTaskDelegate: TaskDelegate, URLSessionDownloadDelegate {

    // MARK: Properties

    var downloadTask: URLSessionDownloadTask { return task as! URLSessionDownloadTask }

    var progress: Progress
    var progressHandler: (closure: Request.ProgressHandler, queue: DispatchQueue)?

    var resumeData: Data?
    override var data: Data? { return resumeData }

    // 这是一个函数
    var destination: DownloadRequest.DownloadFileDestination?

    // 临时url
    var temporaryURL: URL?
    // 存储url
    var destinationURL: URL?

    // 文件路径
    var fileURL: URL? { return destination != nil ? destinationURL : temporaryURL }

    // MARK: Lifecycle

    override init(task: URLSessionTask?) {
        progress = Progress(totalUnitCount: 0)
        super.init(task: task)
    }

    override func reset() {
        super.reset()

        progress = Progress(totalUnitCount: 0)
        resumeData = nil
    }

    // MARK: URLSessionDownloadDelegate

    var downloadTaskDidFinishDownloadingToURL: ((URLSession, URLSessionDownloadTask, URL) -> URL)?
    var downloadTaskDidWriteData: ((URLSession, URLSessionDownloadTask, Int64, Int64, Int64) -> Void)?
    var downloadTaskDidResumeAtOffset: ((URLSession, URLSessionDownloadTask, Int64, Int64) -> Void)?

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL)
    {
        temporaryURL = location

        guard
            let destination = destination,
            let response = downloadTask.response as? HTTPURLResponse
        else { return }

        let result = destination(location, response)
        let destinationURL = result.destinationURL
        let options = result.options

        self.destinationURL = destinationURL

        do {
            if options.contains(.removePreviousFile), FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.removeItem(at: destinationURL)
            }

            if options.contains(.createIntermediateDirectories) {
                let directory = destinationURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            }

            try FileManager.default.moveItem(at: location, to: destinationURL)
        } catch {
            self.error = error
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64)
    {
        if initialResponseTime == nil { initialResponseTime = CFAbsoluteTimeGetCurrent() }

        if let downloadTaskDidWriteData = downloadTaskDidWriteData {
            downloadTaskDidWriteData(
                session,
                downloadTask,
                bytesWritten,
                totalBytesWritten,
                totalBytesExpectedToWrite
            )
        } else {
            progress.totalUnitCount = totalBytesExpectedToWrite
            progress.completedUnitCount = totalBytesWritten

            if let progressHandler = progressHandler {
                progressHandler.queue.async { progressHandler.closure(self.progress) }
            }
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didResumeAtOffset fileOffset: Int64,
        expectedTotalBytes: Int64)
    {
        if let downloadTaskDidResumeAtOffset = downloadTaskDidResumeAtOffset {
            downloadTaskDidResumeAtOffset(session, downloadTask, fileOffset, expectedTotalBytes)
        } else {
            progress.totalUnitCount = expectedTotalBytes
            progress.completedUnitCount = fileOffset
        }
    }
}

// MARK: -

class UploadTaskDelegate: DataTaskDelegate {

    // MARK: Properties

    var uploadTask: URLSessionUploadTask { return task as! URLSessionUploadTask }

    var uploadProgress: Progress
    var uploadProgressHandler: (closure: Request.ProgressHandler, queue: DispatchQueue)?

    // MARK: Lifecycle

    override init(task: URLSessionTask?) {
        uploadProgress = Progress(totalUnitCount: 0)
        super.init(task: task)
    }

    override func reset() {
        super.reset()
        uploadProgress = Progress(totalUnitCount: 0)
    }

    // MARK: URLSessionTaskDelegate

    var taskDidSendBodyData: ((URLSession, URLSessionTask, Int64, Int64, Int64) -> Void)?

    func URLSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64)
    {
        if initialResponseTime == nil { initialResponseTime = CFAbsoluteTimeGetCurrent() }

        if let taskDidSendBodyData = taskDidSendBodyData {
            taskDidSendBodyData(session, task, bytesSent, totalBytesSent, totalBytesExpectedToSend)
        } else {
            uploadProgress.totalUnitCount = totalBytesExpectedToSend
            uploadProgress.completedUnitCount = totalBytesSent

            if let uploadProgressHandler = uploadProgressHandler {
                uploadProgressHandler.queue.async { uploadProgressHandler.closure(self.uploadProgress) }
            }
        }
    }
}
