package com.example;

import com.google.api.gax.rpc.ServerStream;
import com.google.cloud.bigtable.data.v2.BigtableDataClient;
import com.google.cloud.bigtable.data.v2.BigtableDataSettings;
import com.google.cloud.bigtable.data.v2.models.Query;
import com.google.cloud.bigtable.data.v2.models.Row;
import com.google.cloud.bigtable.data.v2.models.RowCell;
import java.util.Scanner;

public class BigtableSidecar {
    public static void main(String[] args) {
        System.err.println("Java Sidecar: Started");
        
        String projectId = "autonomous-mote-782";
        String instanceId = "autopilot-rm-test";
        String tableId = "table-10g";

        try {
            BigtableDataSettings settings = BigtableDataSettings.newBuilder()
                .setProjectId(projectId)
                .setInstanceId(instanceId)
                .build();

            try (BigtableDataClient dataClient = BigtableDataClient.create(settings)) {
                System.err.println("Java Sidecar: Bigtable client initialized for " + projectId + "/" + instanceId);

                Scanner scanner = new Scanner(System.in);
                while (scanner.hasNextLine()) {
                    String line = scanner.nextLine();
                    if ("exit".equalsIgnoreCase(line)) {
                        break;
                    }
                    if ("read".equalsIgnoreCase(line) || "read_real".equalsIgnoreCase(line)) {
                        System.err.println("Java Sidecar: Reading rows from " + tableId + "...");
                        try {
                            Query query = Query.create(tableId).limit(5);
                            ServerStream<Row> rows = dataClient.readRows(query);
                            for (Row row : rows) {
                                System.out.println("Java sidecar: Found row: " + row.getKey().toStringUtf8());
                            }
                        } catch (Exception e) {
                            System.err.println("Java Sidecar Read Error: " + e.getMessage());
                            e.printStackTrace();
                        }
                    } else {
                        System.out.println("Java sidecar says: " + line);
                    }
                }
            }
        } catch (Exception e) {
            System.err.println("Java Sidecar Initialization Error: " + e.getMessage());
            e.printStackTrace();
        }
        
        System.err.println("Java Sidecar: Exiting");
    }
}
