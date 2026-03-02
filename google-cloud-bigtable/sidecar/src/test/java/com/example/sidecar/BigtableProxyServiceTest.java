package com.example.sidecar;

import static org.mockito.ArgumentMatchers.any;
import static org.mockito.Mockito.*;
import static org.junit.Assert.*;

import com.google.cloud.bigtable.data.v2.BigtableDataClient;
import com.google.cloud.bigtable.data.v2.models.Row;
import com.google.cloud.bigtable.data.v2.models.RowCell;
import com.google.cloud.bigtable.data.v2.models.Query;

import com.google.bigtable.v2.ReadRowsRequest;
import com.google.bigtable.v2.ReadRowsResponse;
import com.google.bigtable.v2.BigtableGrpc;
import com.google.protobuf.ByteString;

import io.grpc.stub.StreamObserver;
import org.junit.Before;
import org.junit.Test;
import org.junit.Rule;
import io.grpc.testing.GrpcCleanupRule;
import io.grpc.inprocess.InProcessServerBuilder;
import io.grpc.inprocess.InProcessChannelBuilder;
import io.grpc.ManagedChannel;

import java.io.IOException;
import java.util.Arrays;
import java.util.List;
import java.util.ArrayList;
import java.util.Iterator;

public class BigtableProxyServiceTest {

        @Rule
        public final GrpcCleanupRule grpcCleanup = new GrpcCleanupRule();

        private BigtableProxyService proxyService;
        private BigtableDataClient mockDataClient;
        private BigtableGrpc.BigtableBlockingStub blockingStub;

        @Before
        public void setUp() throws Exception {
                mockDataClient = mock(BigtableDataClient.class);

                // Create an anonymous subclass to inject the mock client directly
                proxyService = new BigtableProxyService("test-project", "test-instance") {
                        @Override
                        protected BigtableDataClient getClient(String tableName, String appProfileId)
                                        throws IOException {
                                return mockDataClient;
                        }
                };

                // Generate a unique in-process server name.
                String serverName = InProcessServerBuilder.generateName();

                // Create a server, add service, start, and register for automatic graceful
                // shutdown.
                grpcCleanup.register(InProcessServerBuilder
                                .forName(serverName).directExecutor().addService(proxyService).build().start());

                // Create a client channel and register for automatic graceful shutdown.
                ManagedChannel channel = grpcCleanup.register(
                                InProcessChannelBuilder.forName(serverName).directExecutor().build());

                // Create a blocking stub
                blockingStub = BigtableGrpc.newBlockingStub(channel);
        }

        @Test
        public void testReadRowsTranslation() {
                // 1. Setup Mock Row Data (the kind returned by Java Veneer)
                RowCell cell1 = RowCell.create(
                                "cf1",
                                ByteString.copyFromUtf8("col1"),
                                1000L,
                                Arrays.asList("label1"),
                                ByteString.copyFromUtf8("val1"));

                RowCell cell2 = RowCell.create(
                                "cf2",
                                ByteString.copyFromUtf8("col2"),
                                2000L,
                                Arrays.asList("label2"),
                                ByteString.copyFromUtf8("val2"));

                Row mockRow1 = Row.create(ByteString.copyFromUtf8("row-key-1"), Arrays.asList(cell1, cell2));

                Row mockRow2 = Row.create(
                                ByteString.copyFromUtf8("row-key-2"),
                                Arrays.asList(RowCell.create("cf1", ByteString.copyFromUtf8("col1"), 3000L,
                                                Arrays.asList(),
                                                ByteString.copyFromUtf8("val3"))));

                @SuppressWarnings("unchecked")
                com.google.api.gax.rpc.ServerStream<Row> mockStream = mock(com.google.api.gax.rpc.ServerStream.class);
                when(mockStream.iterator()).thenReturn(Arrays.asList(mockRow1, mockRow2).iterator());
                when(mockDataClient.readRows(any(Query.class))).thenReturn(mockStream);

                // 3. Execute request via Blocking Stub natively over the full gRPC stack
                ReadRowsRequest request = ReadRowsRequest.newBuilder()
                                .setTableName("projects/test-project/instances/test-instance/tables/test-table")
                                .build();

                Iterator<ReadRowsResponse> responseIterator = blockingStub.readRows(request);

                List<ReadRowsResponse> responses = new ArrayList<>();
                responseIterator.forEachRemaining(responses::add);

                // 4. Verification
                assertEquals(1, responses.size());

                ReadRowsResponse r1 = responses.get(0);
                assertEquals(3, r1.getChunksCount());

                // First Chunk of Row 1
                ReadRowsResponse.CellChunk c1 = r1.getChunks(0);
                assertEquals("row-key-1", c1.getRowKey().toStringUtf8());
                assertEquals("cf1", c1.getFamilyName().getValue());
                assertEquals("col1", c1.getQualifier().getValue().toStringUtf8());
                assertEquals("val1", c1.getValue().toStringUtf8());
                assertFalse("First chunk should not have commitRow set", c1.getCommitRow());

                // Second Chunk of Row 1
                ReadRowsResponse.CellChunk c2 = r1.getChunks(1);
                assertEquals("", c2.getRowKey().toStringUtf8()); // Should be empty for subsequent chunks
                assertEquals("cf2", c2.getFamilyName().getValue());
                assertEquals("col2", c2.getQualifier().getValue().toStringUtf8());
                assertEquals("val2", c2.getValue().toStringUtf8());
                assertTrue("Last chunk of a row MUST have commitRow set to true", c2.getCommitRow());

                // Third Chunk (Row 2)
                ReadRowsResponse.CellChunk c3 = r1.getChunks(2);
                assertEquals("row-key-2", c3.getRowKey().toStringUtf8());
                assertEquals("cf1", c3.getFamilyName().getValue());
                assertEquals("val3", c3.getValue().toStringUtf8());
                assertTrue("Single chunk row MUST have commitRow set to true", c3.getCommitRow());
        }
}
