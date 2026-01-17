/**
 * @format
 * Tests for react-native-background-upload
 */

// Mock react-native
jest.mock('react-native', () => ({
  NativeModules: {
    VydiaRNFileUploader: {
      startUpload: jest.fn(),
      cancelUpload: jest.fn(),
      getFileInfo: jest.fn(),
      addListener: jest.fn(),
      startS3MultipartUpload: jest.fn(),
      getS3UploadStatus: jest.fn(),
      resumeS3Upload: jest.fn(),
    },
  },
  DeviceEventEmitter: {
    addListener: jest.fn(() => ({ remove: jest.fn() })),
  },
}));

const Upload = require('../src/index');
const { NativeModules } = require('react-native');

describe('react-native-background-upload', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('startUpload', () => {
    it('should call native startUpload with options', async () => {
      const options = {
        url: 'https://example.com/upload',
        path: '/path/to/file.mp4',
        method: 'POST',
        type: 'raw',
      };

      NativeModules.VydiaRNFileUploader.startUpload.mockResolvedValue(
        'upload-123',
      );

      const result = await Upload.startUpload(options);

      expect(
        NativeModules.VydiaRNFileUploader.startUpload,
      ).toHaveBeenCalledWith(options);
      expect(result).toBe('upload-123');
    });
  });

  describe('cancelUpload', () => {
    it('should call native cancelUpload with uploadId', async () => {
      NativeModules.VydiaRNFileUploader.cancelUpload.mockResolvedValue(true);

      const result = await Upload.cancelUpload('upload-123');

      expect(
        NativeModules.VydiaRNFileUploader.cancelUpload,
      ).toHaveBeenCalledWith('upload-123');
      expect(result).toBe(true);
    });

    it('should reject if uploadId is not a string', async () => {
      await expect(Upload.cancelUpload(123)).rejects.toThrow(
        'Upload ID must be a string',
      );
    });
  });

  describe('getFileInfo', () => {
    it('should return file info with size as number', async () => {
      NativeModules.VydiaRNFileUploader.getFileInfo.mockResolvedValue({
        name: 'video.mp4',
        size: '12345678',
        exists: true,
        extension: 'mp4',
        mimeType: 'video/mp4',
      });

      const result = await Upload.getFileInfo('/path/to/video.mp4');

      expect(result.size).toBe(12345678);
      expect(typeof result.size).toBe('number');
    });
  });

  describe('addListener', () => {
    it('should register event listener with prefixed event name', () => {
      const callback = jest.fn();
      Upload.addListener('progress', 'upload-123', callback);

      expect(
        require('react-native').DeviceEventEmitter.addListener,
      ).toHaveBeenCalledWith('RNFileUploader-progress', expect.any(Function));
    });

    it('should filter events by uploadId', () => {
      const callback = jest.fn();
      const { DeviceEventEmitter } = require('react-native');

      let capturedHandler;
      DeviceEventEmitter.addListener.mockImplementation((event, handler) => {
        capturedHandler = handler;
        return { remove: jest.fn() };
      });

      Upload.addListener('progress', 'upload-123', callback);

      // Should call callback for matching uploadId
      capturedHandler({ id: 'upload-123', progress: 50 });
      expect(callback).toHaveBeenCalledWith({ id: 'upload-123', progress: 50 });

      callback.mockClear();

      // Should not call callback for different uploadId
      capturedHandler({ id: 'upload-456', progress: 75 });
      expect(callback).not.toHaveBeenCalled();
    });

    it('should call callback for all uploads when uploadId is null', () => {
      const callback = jest.fn();
      const { DeviceEventEmitter } = require('react-native');

      let capturedHandler;
      DeviceEventEmitter.addListener.mockImplementation((event, handler) => {
        capturedHandler = handler;
        return { remove: jest.fn() };
      });

      Upload.addListener('progress', null, callback);

      capturedHandler({ id: 'upload-123', progress: 50 });
      expect(callback).toHaveBeenCalled();

      callback.mockClear();

      capturedHandler({ id: 'upload-456', progress: 75 });
      expect(callback).toHaveBeenCalled();
    });
  });
});

describe('S3 Multipart Upload', () => {
  beforeEach(() => {
    jest.clearAllMocks();
  });

  describe('startS3MultipartUpload', () => {
    it('should call native startS3MultipartUpload with correct options', async () => {
      const options = {
        path: '/path/to/large-video.mp4',
        s3Multipart: true,
        s3MultipartConfig: {
          uploadId: 'aws-upload-id-123',
          objectKey: 'uploads/video.mp4',
          presignedUrlEndpoint: 'https://api.example.com/presign',
          completeEndpoint: 'https://api.example.com/complete',
          clientId: 'media-001',
          partSize: 5 * 1024 * 1024,
        },
      };

      NativeModules.VydiaRNFileUploader.startS3MultipartUpload.mockResolvedValue(
        'media-001',
      );

      const result = await Upload.startS3MultipartUpload(options);

      expect(
        NativeModules.VydiaRNFileUploader.startS3MultipartUpload,
      ).toHaveBeenCalledWith(options);
      expect(result).toBe('media-001');
    });
  });

  describe('getS3UploadStatus', () => {
    it('should return upload status for existing upload', async () => {
      const status = {
        clientId: 'media-001',
        uploadId: 'aws-upload-id-123',
        objectKey: 'uploads/video.mp4',
        completedParts: [
          { partNumber: 1, etag: 'etag-1' },
          { partNumber: 2, etag: 'etag-2' },
        ],
        totalParts: 5,
        inProgress: false,
      };

      NativeModules.VydiaRNFileUploader.getS3UploadStatus.mockResolvedValue(
        status,
      );

      const result = await Upload.getS3UploadStatus({ clientId: 'media-001' });

      expect(result).toEqual(status);
      expect(result.completedParts).toHaveLength(2);
    });

    it('should return null for non-existent upload', async () => {
      NativeModules.VydiaRNFileUploader.getS3UploadStatus.mockResolvedValue(
        null,
      );

      const result = await Upload.getS3UploadStatus({
        clientId: 'non-existent',
      });

      expect(result).toBeNull();
    });
  });

  describe('resumeS3Upload', () => {
    it('should call native resumeS3Upload', async () => {
      NativeModules.VydiaRNFileUploader.resumeS3Upload.mockResolvedValue(true);

      const result = await Upload.resumeS3Upload({ clientId: 'media-001' });

      expect(
        NativeModules.VydiaRNFileUploader.resumeS3Upload,
      ).toHaveBeenCalledWith({
        clientId: 'media-001',
      });
      expect(result).toBe(true);
    });
  });

  describe('part_completed event', () => {
    it('should handle part_completed events', () => {
      const callback = jest.fn();
      const { DeviceEventEmitter } = require('react-native');

      let capturedHandler;
      DeviceEventEmitter.addListener.mockImplementation((event, handler) => {
        capturedHandler = handler;
        return { remove: jest.fn() };
      });

      Upload.addListener('part_completed', 'media-001', callback);

      expect(DeviceEventEmitter.addListener).toHaveBeenCalledWith(
        'RNFileUploader-part_completed',
        expect.any(Function),
      );

      capturedHandler({
        id: 'media-001',
        partNumber: 3,
        totalParts: 10,
        etag: 'etag-abc123',
      });

      expect(callback).toHaveBeenCalledWith({
        id: 'media-001',
        partNumber: 3,
        totalParts: 10,
        etag: 'etag-abc123',
      });
    });
  });
});

describe('default export', () => {
  it('should export all functions', () => {
    expect(Upload.default).toHaveProperty('startUpload');
    expect(Upload.default).toHaveProperty('cancelUpload');
    expect(Upload.default).toHaveProperty('addListener');
    expect(Upload.default).toHaveProperty('getFileInfo');
    expect(Upload.default).toHaveProperty('startS3MultipartUpload');
    expect(Upload.default).toHaveProperty('getS3UploadStatus');
    expect(Upload.default).toHaveProperty('resumeS3Upload');
  });
});
