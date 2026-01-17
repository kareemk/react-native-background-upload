declare module "react-native-background-upload" {
    import type { EventSubscription } from 'react-native';

    export interface EventData {
        id: string;
    }

    export interface ProgressData extends EventData {
        progress: number
    }

    export interface ErrorData extends EventData {
        error: string
    }

    export interface CompletedData extends EventData {

        responseCode: number
        responseBody: string
    }
    export type FileInfo = {
        name: string
        exists: boolean
        size?: number
        extension?: string
        mimeType?: string
    }


    export type NotificationOptions = {
        /**
         * Enable or diasable notifications. Works only on Android version < 8.0 Oreo. On Android versions >= 8.0 Oreo is required by Google's policy to display a notification when a background service run  { enabled: true }
         */
        enabled: boolean
        /**
         * Autoclear notification on complete  { autoclear: true }
         */
        autoClear: boolean
        /**
         * Sets android notificaion channel  { notificationChannel: "My-Upload-Service" }
         */
        notificationChannel: string
        /**
         * Sets whether or not to enable the notification sound when the upload gets completed with success or error   { enableRingTone: true }
         */
        enableRingTone: boolean
        /**
         * Sets notification progress title  { onProgressTitle: "Uploading" }
         */
        onProgressTitle: string
        /**
         * Sets notification progress message  { onProgressMessage: "Uploading new video" }
         */
        onProgressMessage: string
        /**
         * Sets notification complete title  { onCompleteTitle: "Upload finished" }
         */
        onCompleteTitle: string
        /**
         * Sets notification complete message  { onCompleteMessage: "Your video has been uploaded" }
         */
        onCompleteMessage: string
        /**
         * Sets notification error title   { onErrorTitle: "Upload error" }
         */
        onErrorTitle: string
        /**
         * Sets notification error message   { onErrorMessage: "An error occured while uploading a video" }
         */
        onErrorMessage: string
        /**
         * Sets notification cancelled title   { onCancelledTitle: "Upload cancelled" }
         */
        onCancelledTitle: string
        /**
         * Sets notification cancelled message   { onCancelledMessage: "Video upload was cancelled" }
         */
        onCancelledMessage: string
    }

    export interface UploadOptions {
        url: string;
        path: string;
        type?: 'raw' | 'multipart';
        method?: 'POST' | 'GET' | 'PUT' | 'PATCH' | 'DELETE';
        customUploadId?: string;
        headers?: {
            [index: string]: string
        };
        // Android notification settings
        notification?: Partial<NotificationOptions>
        /**
         * AppGroup defined in XCode for extensions. Necessary when trying to upload things via this library
         * in the context of ShareExtension.
         */
        appGroup?: string;
        // Necessary only for multipart type upload
        field?: string
    }

    export interface MultipartUploadOptions extends UploadOptions {
        type: 'multipart'
        field: string
        parameters?: {
            [index: string]: string
        }
    }

    type uploadId = string

    export type UploadListenerEvent = 'progress' | 'error' | 'completed' | 'cancelled' | 'part_completed'

    export interface S3MultipartConfig {
        uploadId: string;
        objectKey: string;
        presignedUrlEndpoint: string;
        completeEndpoint: string;
        clientId: string;
        partSize?: number;
    }

    export interface S3MultipartUploadOptions extends UploadOptions {
        s3Multipart: true;
        s3MultipartConfig: S3MultipartConfig;
    }

    export interface S3PartCompletedData extends EventData {
        partNumber: number;
        totalParts: number;
        etag: string;
    }

    export interface S3UploadStatus {
        clientId: string;
        uploadId: string;
        objectKey: string;
        completedParts: { partNumber: number; etag: string }[];
        totalParts: number;
        inProgress: boolean;
    }

    export default class Upload {
        static startUpload(options: UploadOptions | MultipartUploadOptions): Promise<uploadId>
        static addListener(event: 'progress', uploadId: uploadId | null, callback: (data: ProgressData ) => void): EventSubscription
        static addListener(event: 'error', uploadId: uploadId | null, callback: (data: ErrorData) => void): EventSubscription
        static addListener(event: 'completed', uploadId: uploadId | null, callback: (data: CompletedData) => void): EventSubscription
        static addListener(event: 'cancelled', uploadId: uploadId | null, callback: (data: EventData) => void): EventSubscription
        static addListener(event: 'part_completed', uploadId: uploadId | null, callback: (data: S3PartCompletedData) => void): EventSubscription
        static getFileInfo(path: string): Promise<FileInfo>
        static cancelUpload(uploadId: uploadId): Promise<boolean>
        static startS3MultipartUpload(options: S3MultipartUploadOptions): Promise<uploadId>
        static getS3UploadStatus(params: { clientId: string }): Promise<S3UploadStatus | null>
        static resumeS3Upload(params: { clientId: string }): Promise<boolean>
    }

}
